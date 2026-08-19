// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// For license information, please see license.txt

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../api/client.dart';
import '../database/daos/media_cache_dao.dart';
import '../database/daos/pending_attachment_dao.dart';
import '../models/media_store_usage.dart';
import '../utils/media_store.dart';
import '../utils/sdk_log.dart';
import '../api/exceptions.dart';
import '../concurrency/concurrency_pool.dart';
import '../concurrency/connectivity_watcher.dart';
import '../database/app_database.dart';
import '../database/daos/doctype_meta_dao.dart';
import '../database/daos/outbox_dao.dart';
import '../database/daos/sdk_meta_dao.dart';
import '../database/daos/translation_dao.dart';
import '../models/closure_result.dart';
import '../models/doc_type_meta.dart';
import '../models/offline_mode.dart';
import '../models/offline_mode_notifier.dart';
import '../models/session_user.dart';
import '../query/unified_resolver.dart';
import '../services/auth_service.dart';
import '../services/local_writer.dart';
import '../services/session_health.dart';
import '../services/meta_service.dart';
import '../services/permission_service.dart';
import '../services/session_user_service.dart';
import '../services/sync_controller.dart';
import '../services/sync_engine_builder.dart';
import '../services/sync_service.dart';
import '../services/offline_repository.dart';
import '../services/offline_transition_service.dart';
import '../services/link_option_service.dart';
import '../services/translation_service.dart';
import '../security/security_check.dart';
import '../security/frappe_security_service.dart';
import '../sync/cursor.dart';
import '../sync/pull_engine.dart';
import '../sync/push_engine.dart';
import '../sync/sync_details.dart';
import '../sync/sync_state.dart';
import '../sync/sync_state_notifier.dart';

/// Main SDK initialization class for easy setup
class FrappeSDK {
  final String baseUrl;
  final String? databaseAppName;

  /// Optional payload transformer; passed to the push pipeline. See
  /// [PayloadTransformerFn] in `push_engine.dart`. Apps use this to
  /// override push payloads (e.g. SNF auto-submits submittable doctypes
  /// to `docstatus=1` on sync).
  final PayloadTransformerFn? payloadTransformer;

  /// Called when SQLite FFI initialization fails before the MethodChannel
  /// fallback activates. Use to record a non-fatal Crashlytics event.
  /// The SDK continues normally on the MethodChannel path regardless.
  final void Function(Object, StackTrace)? onFfiInitFailure;

  /// Rows per page for `PullEngine`. Default 500. Increase for servers with
  /// fast response times and large doctypes; decrease if requests time out.
  final int pullPageSize;

  /// Rows per page for `SyncService` batch apply. Default 1000.
  final int syncServicePageSize;

  /// Rows per page when listing child-table documents. Default 1000.
  final int listChildDocsPageSize;

  /// Rows per page when fetching full document payloads (with children). Default 1000.
  final int listFullDocsPageSize;

  /// Rows per page for general list queries. Default 20.
  final int listDefaultPageSize;

  final bool tamperProtectionEnabled;
  final Set<SecurityCheck> tamperProtectionChecks;
  final int tamperProtectionRestartGapMs;

  FrappeClient? _client;
  AppDatabase? _database;
  AuthService? _authService;
  MetaService? _metaService;
  PermissionService? _permissionService;
  TranslationService? _translationService;
  SyncService? _syncService;
  OfflineRepository? _repository;
  OfflineTransitionService? _offlineTransitionService;
  LinkOptionService? _linkOptionService;
  UnifiedResolver? _resolver;
  SessionUserService? _sessionUserService;
  FrappeSecurityService? _securityService;

  // Push/pull engines + controller wired by [SyncEngineBuilder]. They
  // share `_syncStateNotifier` so the single observable surface for sync
  // activity flows through one notifier. The pools and notifier are kept
  // here so future consumers (e.g. a `sdk.syncState` stream getter or
  // runtime resize) can access them; the analyzer's unused-field warning
  // is suppressed until those public getters land.
  // ignore: unused_field
  ConcurrencyPool? _pushPool;
  // ignore: unused_field
  ConcurrencyPool? _pullPool;
  PushEngine? _pushEngine;
  // ignore: unused_field
  PullEngine? _pullEngine;
  Future<bool> Function()? _isOnlineOverrideForTesting;
  SyncController? _syncController;
  SyncStateNotifier? _syncStateNotifier;

  /// Live sync-state notifier. Non-null after [initialize] completes.
  /// Wire into [SyncStatusBar] to surface pull/push activity in the UI.
  SyncStateNotifier? get syncStateNotifier => _syncStateNotifier;

  /// Liveness of the stored credential. Null before [initialize]. Hosts should
  /// prompt for re-login on [SessionHealth.expired] and stay quiet on
  /// [SessionHealth.degraded], which clears by itself.
  ///
  /// DELIBERATELY NOT disposed by [dispose], unlike the notifiers torn down
  /// there. [dispose]'s contract keeps the instance reusable, and a host that
  /// wired this notifier into a long-lived widget (an auth gate outliving one
  /// SDK lifecycle is the normal shape) would get "used after dispose" on the
  /// next rebuild. It holds no stream, subscription or timer, so leaving it
  /// alive costs nothing; the [AuthService] that owns it is dropped with the
  /// rest and a fresh [initialize] publishes a new one.
  ValueNotifier<SessionHealth>? get sessionHealth =>
      _authService?.sessionHealth;

  /// The tamper-detection service. Non-null after [initialize] completes.
  FrappeSecurityService get security {
    _assertInitialized();
    return _securityService!;
  }

  bool _initialized = false;

  /// Set once [dispose] begins. The fire-and-forget initial sync started by
  /// login()/verifyLoginOtp()/initialize() (`unawaited(_initialMetaAndDataSync())`)
  /// can still be mid-flight when the consumer disposes the SDK; this flag lets
  /// those background steps bail instead of dereferencing services [dispose]
  /// has nulled. See [_runInitialMetaAndDataSync].
  bool _disposed = false;

  /// One-shot lock for [initialize]. Set to a non-null Completer for the
  /// duration of an in-flight `initialize()` call so concurrent callers
  /// await the same future instead of racing through the body and each
  /// constructing parallel sets of services. Cleared when the body
  /// finishes (success or failure); on failure callers can retry.
  Completer<void>? _initInFlight;

  /// Coalesces concurrent [_initialMetaAndDataSync] runs. login(),
  /// verifyLoginOtp(), and initialize() each fire it `unawaited`; two rapid
  /// auth events (or a login racing an in-progress run) would otherwise
  /// execute two concurrent meta+config+closure pulls, both writing
  /// `doctype_meta`/`sdk_meta` with no ordering guarantee (PR#36 round-4 H5).
  Completer<void>? _metaSyncInFlight;

  /// Set when [OfflineTransitionService.runDrainAndWipe] is fired
  /// in the background from [initialize] / [login]. [_runUpgradeClosurePull]
  /// awaits this before doing any per-doctype-table writes so a concurrent
  /// `wipeOfflineDocumentTables()` cannot drop a table mid-pull. Cleared
  /// once the drain settles.
  Future<void>? _pendingDrain;

  /// Cached synchronous online state — seeded from
  /// [ConnectivityWatcher.production] at init and kept fresh by the
  /// connectivity subscription so mid-session network flips reach the
  /// resolver without a manual probe. Conservative default (false) means
  /// the resolver starts in offline-only mode and switches to
  /// background-refresh mode once the first connectivity check resolves.
  bool _cachedOnline = false;

  /// Watcher + subscription that keep [_cachedOnline] in sync with the
  /// platform connectivity stream. Both are set up in [initialize] and
  /// torn down in [dispose].
  ConnectivityWatcher? _connectivityWatcher;
  StreamSubscription<bool>? _connectivitySub;

  /// Install-stable `mobile_uuid` read once from secure storage at init
  /// and reused by every push / link-option lambda. Avoids the secure-
  /// storage round-trip per outbox dispatch.
  String? _mobileUuid;

  /// Shared mutable holder for [OfflineMode]. Constructed once per session
  /// in [initialize] / [forTesting] and threaded into [OfflineRepository],
  /// [SyncService], and [UnifiedResolver]. A mid-session flip via
  /// [_applyOfflineFlag] is visible to every service through the notifier.
  OfflineModeNotifier? _modeNotifier;

  /// Fires (with `null`) after each batch pull operation completes —
  /// [_runUpgradeClosurePull] and [forcePullAll]. Home screen subscribes to
  /// this to refresh its document counts without polling.
  StreamController<void>? _syncCompleteController;

  /// Subscribe to receive a `void` event each time a batch pull finishes.
  /// The stream is broadcast so multiple listeners are safe.
  Stream<void>? get syncComplete$ => _syncCompleteController?.stream;

  /// Session-bound offline mode. Reads through [_modeNotifier] so mid-session
  /// flips by [_applyOfflineFlag] take effect immediately.
  OfflineMode get _offlineMode =>
      _modeNotifier?.value ??
      const OfflineMode(enabled: true, isPersisted: true);

  @visibleForTesting
  OfflineMode get offlineModeForTesting => _offlineMode;

  /// Test seam: directly mutate the shared notifier without going through
  /// [_applyOfflineFlag] (no persist, no transition dispatch).
  @visibleForTesting
  void flipOfflineModeForTesting(OfflineMode next) {
    _modeNotifier?.value = next;
  }

  FrappeSDK({
    required this.baseUrl,
    this.databaseAppName,
    this.payloadTransformer,
    this.onFfiInitFailure,
    this.pullPageSize = 500,
    this.syncServicePageSize = 1000,
    this.listChildDocsPageSize = 1000,
    this.listFullDocsPageSize = 1000,
    this.listDefaultPageSize = 20,
    this.tamperProtectionEnabled = false,
    this.tamperProtectionChecks = const {},
    this.tamperProtectionRestartGapMs = 600000,
  });

  /// Test-only constructor: accepts a pre-built [AppDatabase] (e.g. in-memory).
  /// Wires all services directly without calling [initialize()].
  /// Avoids FlutterSecureStorage (not available in unit/widget tests).
  ///
  /// Defaults to offline-mode (`enabled: true, isPersisted: true`) so
  /// existing tests that don't pass [offlineMode] keep their previous
  /// behaviour. Tests exercising the online-mode passthroughs should
  /// pass `offlineMode: const OfflineMode(enabled: false, isPersisted: true)`.
  @visibleForTesting
  FrappeSDK.forTesting(
    this.baseUrl,
    AppDatabase database, {
    OfflineMode offlineMode = const OfflineMode(
      enabled: true,
      isPersisted: true,
    ),
    http.Client? httpClient,
    this.pullPageSize = 500,
    this.syncServicePageSize = 1000,
    this.listChildDocsPageSize = 1000,
    this.listFullDocsPageSize = 1000,
    this.listDefaultPageSize = 20,
    this.tamperProtectionEnabled = false,
    this.tamperProtectionChecks = const {},
    this.tamperProtectionRestartGapMs = 600000,
  }) : databaseAppName = null,
       payloadTransformer = null,
       onFfiInitFailure = null {
    _database = database;
    _modeNotifier = OfflineModeNotifier(offlineMode);
    _syncCompleteController = StreamController<void>.broadcast();
    // Create FrappeClient directly — avoids AuthService.initialize() which
    // writes to FlutterSecureStorage and is unavailable in widget tests.
    // [httpClient] lets tests stub the transport (e.g. the /sync_details
    // pre-flight) without a real network.
    _client = FrappeClient(
      baseUrl,
      httpClient: httpClient,
      listChildDocsPageSize: listChildDocsPageSize,
      listFullDocsPageSize: listFullDocsPageSize,
      listDefaultPageSize: listDefaultPageSize,
    );
    // Use AuthService.forTesting so the client and database are wired up
    // without touching FlutterSecureStorage. This means sdk.auth methods
    // (e.g. getOrCreateMobileUuid, restoreSession) won't throw "not
    // initialized" if called from any production code path under test.
    _authService = AuthService.forTesting(_client!, database: database);
    _metaService = MetaService(_client!, _database!);
    final testMetaService = _metaService!;
    final testMetaFn = testMetaService.getMeta;
    // `currentUserId` is read lazily, so it is safe that `_sessionUserService`
    // is created further down — same wiring as production (see _doInitialize).
    final testLocalWriter = LocalWriter(
      database.rawDatabase,
      testMetaFn,
      currentUserId: () => _sessionUserService?.current?.name,
    );
    _repository = OfflineRepository(
      _database!,
      localWriter: testLocalWriter,
      offlineModeNotifier: _modeNotifier!,
      client: _client,
      metaFetcher: testMetaFn,
    );
    _wireMetaRefreshInvalidation();
    _permissionService = PermissionService(_client!, _database!);
    final translationDao = TranslationDao(database.rawDatabase);
    _translationService = TranslationService(_client!)
      ..injectDao(translationDao);
    _syncService = SyncService(
      _client!,
      _repository!,
      _database!,
      getMobileUuid: () async => 'test-uuid',
      offlineModeNotifier: _modeNotifier!,
      pageSize: syncServicePageSize,
    );
    final testResolver = UnifiedResolver(
      db: database.rawDatabase,
      metaDao: DoctypeMetaDao(database.rawDatabase),
      isOnline: () => false,
      backgroundFetch: (_, _) async {},
      metaResolver: testMetaFn,
      offlineModeNotifier: _modeNotifier!,
      client: _client,
    );
    _resolver = testResolver;
    _linkOptionService = LinkOptionService(
      testResolver,
      testMetaFn,
      syncComplete$: _syncCompleteController?.stream,
      translate: (s) => _translationService?.translate(s) ?? s,
    );
    _offlineTransitionService = OfflineTransitionService(
      database: _database!,
      drainSyncFactory: () async => SyncService(
        _client!,
        _repository!,
        _database!,
        getMobileUuid: () async => 'test-uuid',
        offlineMode: const OfflineMode(enabled: true, isPersisted: true),
        pageSize: syncServicePageSize,
      ),
      residueCounter: _residueCount,
    );
    _sessionUserService = SessionUserService(_database!.rawDatabase);
    _securityService = FrappeSecurityService(
      database: database,
      enabled: tamperProtectionEnabled,
      checks: tamperProtectionChecks,
      restartGapMs: tamperProtectionRestartGapMs,
    );
    _initialized = true;
  }

  /// Wires a server meta refresh to offline-cache invalidation: whenever
  /// [MetaService] rewrites a doctype's meta (boot sync, reconnect resync,
  /// config refresh) it evicts [OfflineRepository]'s per-doctype cache so the
  /// next saveDocument reads the fresh schema rather than a session-stale
  /// snapshot that would silently drop newly-added fields. Called from BOTH
  /// [_doInitialize] (production) and [FrappeSDK.forTesting] so tests exercise
  /// the exact production wiring.
  void _wireMetaRefreshInvalidation() {
    _metaService!.onMetaRefreshed = _repository!.invalidateMetaCacheFor;
  }

  /// Initialize SDK (call this first).
  ///
  /// [autoRestoreAndSync] (optional, default `false`):
  /// - tries to restore session (mobile_auth / OAuth / API key)
  /// - if successful, runs an initial metadata + data sync for mobile doctypes
  Future<void> initialize([bool autoRestoreAndSync = false]) async {
    if (_initialized) return;
    final inFlight = _initInFlight;
    if (inFlight != null) return inFlight.future;
    final completer = Completer<void>();
    _initInFlight = completer;
    try {
      await _doInitialize(autoRestoreAndSync);
      completer.complete();
    } catch (e, st) {
      // _doInitialize creates `_syncCompleteController` mid-flight and
      // may throw after that line. `dispose()` only runs against a
      // fully-initialized SDK, so without this cleanup the orphan
      // StreamController leaks (subscribers never see done, GC can't
      // reach it). PR#36 round-2 M9.
      final ctrl = _syncCompleteController;
      if (ctrl != null && !ctrl.isClosed) {
        await ctrl.close();
      }
      _syncCompleteController = null;
      completer.completeError(e, st);
      rethrow;
    } finally {
      _initInFlight = null;
    }
  }

  Future<void> _doInitialize(bool autoRestoreAndSync) async {
    _database = await AppDatabase.getInstance(
      appName: databaseAppName,
      onFfiInitFailure: onFfiInitFailure,
    );
    _securityService = FrappeSecurityService(
      database: _database!,
      enabled: tamperProtectionEnabled,
      checks: tamperProtectionChecks,
      restartGapMs: tamperProtectionRestartGapMs,
    );
    _authService = AuthService();
    _authService!.initialize(baseUrl, database: _database);

    // Use the same authenticated client instance everywhere so that
    // meta/sync/link-options calls always carry the Bearer token / API key.
    _client = _authService!.client;

    // Read the install-stable mobile_uuid ONCE up front so the per-push
    // and per-link-options lambdas below can return it without hitting
    // secure storage again on every dispatch (L1).
    _mobileUuid = await _authService!.getOrCreateMobileUuid();

    // Resolve session-bound offline mode BEFORE constructing services so
    // every service receives the correct mode through its constructor.
    final persistedMode = await SdkMetaDao(
      _database!.rawDatabase,
    ).readOfflineMode();
    final resolvedMode = await _resolveBootMode(persistedMode);
    _modeNotifier = OfflineModeNotifier(resolvedMode);
    _syncCompleteController = StreamController<void>.broadcast();

    _metaService = MetaService(_client!, _database!);
    final rawDb = _database!.rawDatabase;
    // Create + restore the session user BEFORE building the sync engine: the
    // push-engine error-log capture holds onto this reference, so it must be
    // the real (restored) instance, not a null placeholder. Creating it after
    // the build (as before) left the capture reading a null service forever,
    // so every Mobile Error Log row had an empty error_user / roles.
    _sessionUserService = SessionUserService(rawDb);
    await _sessionUserService!.restoreFromDb();
    final metaSvc = _metaService!;
    final metaFn = metaSvc.getMeta;
    // `currentUserId` lets LocalWriter predict Frappe's `owner` / `creation` /
    // `modified_by` for a document created on this device, so the creator's own
    // `owner = <me>` list shows it before it ever syncs. Read through the
    // service on every call (not captured once) so login / logout mid-session
    // is reflected immediately.
    final localWriter = LocalWriter(
      rawDb,
      metaFn,
      currentUserId: () => _sessionUserService?.current?.name,
    );
    _repository = OfflineRepository(
      _database!,
      localWriter: localWriter,
      offlineModeNotifier: _modeNotifier!,
      client: _client!,
      metaFetcher: metaFn,
    );
    _permissionService = PermissionService(_client!, _database!);
    final translationDao = TranslationDao(rawDb);
    _translationService = TranslationService(_client!)
      ..injectDao(translationDao);
    // Build the sync engine pack (PushEngine + PullEngine + SyncController +
    // shared SyncStateNotifier + two ConcurrencyPools). PushEngine becomes
    // the production push driver. SyncService below holds a closure that
    // delegates pushSync() to PushEngine.runOnce().
    final pack = await SyncEngineBuilder.build(
      database: _database!,
      client: _client!,
      metaResolver: metaFn,
      runPullFn: _runPullForController,
      applyServerDoc: (doctype, doc) async {
        final serverName = doc['name'] as String? ?? '';
        await _repository!.applyServerDocument(
          doctype: doctype,
          serverName: serverName,
          data: doc,
        );
      },
      runPullForDoctypes: _runPullForDoctypesViaController,
      // mobile_control is a hard SDK dependency (server-side Frappe app
      // providing JWT auth + mobile_uuid injection + dedup-on-INSERT).
      // Enabling L2 here lets IdempotencyStrategy short-circuit duplicate
      // INSERTs after a ghost-success retry instead of falling back to L3
      // (extra GET-by-mobile_uuid before each retry).
      serverHasDedupHook: true,
      // Closes the SDK meta-cache race: PullEngine reconciles the
      // on-disk schema against the meta it's about to apply, just before
      // each doctype's pull loop runs.
      schemaReconciler: _repository!.reconcileParentTableForMeta,
      payloadTransformer: payloadTransformer,
      pullPageSize: pullPageSize,
      // Supplies error-log capture with the current user identity + roles.
      sessionUserService: _sessionUserService,
    );
    _syncStateNotifier = pack.notifier;
    _pushPool = pack.pushPool;
    _pullPool = pack.pullPool;
    _pushEngine = pack.pushEngine;
    _pullEngine = pack.pullEngine;
    _syncController = pack.controller;

    // Surface MetaService.checkAndSyncDoctypes failures on the observable
    // SyncState instead of stranding them in `debugPrint` — UI can now
    // expose a "meta failures: N" indicator and list affected doctypes.
    _metaService!.onMetaSyncFailure = (doctype, error) {
      _syncStateNotifier?.recordMetaSyncFailure(doctype, error.toString());
    };
    _metaService!.onMetaSyncRecovered = (doctype) {
      _syncStateNotifier?.clearMetaSyncFailure(doctype);
    };
    _wireMetaRefreshInvalidation();

    // This server's `frappe.client.get_list` rejects a wildcard `fields:['*']`
    // ("Field not permitted in query: *"). Expand '*' to the doctype's real
    // columns via the meta cache (~free after first load). Covers foreground
    // reads, generic list screens (query_builder / .doc().get()), and the
    // flat-doctype pull engine — all route through DoctypeService.list.
    _client!.doctype.starFieldsResolver = (doctype) async {
      final m = await _metaService!.getMeta(doctype);
      return listableFieldnamesForStar(m);
    };

    _syncService = SyncService(
      _client!,
      _repository!,
      _database!,
      getMobileUuid: _resolveMobileUuid,
      offlineModeNotifier: _modeNotifier!,
      pushRunner: () => _pushEngine!.runOnce(),
      // Parity with PullEngine's guard: SyncService's pull paths
      // (pullSyncWaiting, pullSyncMany, forcePullAll) defer a doctype while a
      // push is active for it, so a pull can't insert a duplicate over an
      // in-flight push INSERT (#43). OutboxDao is a thin wrapper over rawDb.
      hasActivePush: (doctype) => OutboxDao(rawDb).hasActivePushFor(doctype),
      pageSize: syncServicePageSize,
    );
    // Build UnifiedResolver — single read path for all offline queries.
    // Probe connectivity once here AND subscribe to the platform
    // connectivity stream so mid-session network flips refresh
    // `_cachedOnline` immediately. Downstream callers (resolver,
    // `_initialMetaAndDataSync`) read `_cachedOnline` instead of probing
    // again, keeping the hot path to a single field read.
    // The same probe/edge also publishes onto the SyncStateNotifier —
    // it is the ONLY publisher of SyncState.isOnline, which otherwise
    // stays at its initial `false` and pins SyncStatusBar on "Offline".
    final watcher = await ConnectivityWatcher.production();
    _connectivityWatcher = watcher;
    _cachedOnline = watcher.isOnline;
    _syncStateNotifier?.updateOnline(watcher.isOnline);
    _connectivitySub = watcher.onChange.listen((online) {
      _cachedOnline = online;
      _syncStateNotifier?.updateOnline(online);
    });
    final syncSvc = _syncService!;
    final resolver = UnifiedResolver(
      db: rawDb,
      metaDao: DoctypeMetaDao(rawDb),
      isOnline: () => _cachedOnline,
      backgroundFetch: (doctype, _) async {
        // Use the waiting variant — when the closure-pull batch holds
        // the SyncMutex, we want this call to queue behind it instead
        // of returning "Sync already in progress" silently. The picker
        // that triggered us is showing empty until data lands, so
        // dropping the request is the worse outcome.
        try {
          await syncSvc.pullSyncWaiting(doctype: doctype);
        } catch (e, st) {
          sdkLog('FrappeSDK: background pullSync($doctype) failed — $e\n$st');
        }
      },
      metaResolver: metaFn,
      offlineModeNotifier: _modeNotifier!,
      client: _client!,
    );
    _resolver = resolver;
    _linkOptionService = LinkOptionService(
      resolver,
      metaFn,
      syncComplete$: _syncCompleteController?.stream,
      // Translate Link / Table MultiSelect option titles whose target
      // doctype is a translated_doctype (Frappe `__()` parity). Reads the
      // field at call time so a post-logout reset / locale change is honored.
      translate: (s) => _translationService?.translate(s) ?? s,
    );

    // Build the offline-transition service. It owns its own broadcast
    // stream; consumers subscribe via `sdk.offlineTransition.stream`.
    // The drain factory builds a one-shot SyncService with offline mode
    // forced on so its public methods actually run, regardless of the
    // session-bound mode (which is `false` when the transition fires).
    _offlineTransitionService = OfflineTransitionService(
      database: _database!,
      drainSyncFactory: () async => SyncService(
        _client!,
        _repository!,
        _database!,
        getMobileUuid: _resolveMobileUuid,
        offlineMode: const OfflineMode(enabled: true, isPersisted: true),
        // The drain SyncService delegates to the same PushEngine instance
        // the SDK owns; the drain runs PushEngine.runOnce() to drain the
        // outbox before the local-state wipe.
        pushRunner: () => _pushEngine!.runOnce(),
        pageSize: syncServicePageSize,
      ),
      residueCounter: _residueCount,
    );

    // _sessionUserService is created + restored earlier (before the sync-engine
    // build) so the error-log capture sees the real instance. See above.

    // If a persisted SessionUser carries a language preference, warm the
    // translation cache from SQLite before the UI renders. This is a fast
    // read (<5 ms) — no network. Currently inert because
    // _setSessionUserFromLoginResponse does not yet persist language; it
    // becomes effective once app-level locale persistence lands (Task 5).
    final restoredLang = _sessionUserService?.current?.language;
    if (restoredLang != null && restoredLang.isNotEmpty) {
      await _translationService?.setLocale(restoredLang);
    }

    _initialized = true;

    if (autoRestoreAndSync) {
      // Pass the connectivity signal so restoreSession never fires a proactive
      // token refresh while offline (which would wipe the token on the
      // guaranteed NetworkException and strand an offline user at login).
      final restored = await _authService!.restoreSession(
        isOnline: _cachedOnline,
      );
      if (restored) {
        // Kick off the offline → online transition in the background
        // (do NOT await). Reasoning: initialize() runs before runApp()
        // mounts any widgets. Awaiting would deadlock on
        // [TransitionDrainFailed] because no UI exists to call
        // retry()/forceExit() — see Spec §10.4(b). Letting it run
        // concurrently lets the consumer mount [OfflineTransitionGuard]
        // and drive the flow once the widget tree is up.
        if (persistedMode.isPersisted &&
            !persistedMode.enabled &&
            await _hasResidualOfflineState()) {
          // Track the drain future so [_runUpgradeClosurePull] can await
          // it before writing to per-doctype tables — preventing a wipe
          // from racing with a closure pull mid-write. Cannot await here
          // because [TransitionDrainFailed] parks waiting for retry() /
          // forceExit() from the UI, which isn't mounted yet.
          _pendingDrain = _offlineTransitionService!
              .runDrainAndWipe()
              .whenComplete(() => _pendingDrain = null);
          unawaited(_pendingDrain!);
        }
        // Awaited intentionally — keeps the boot pipeline sequential
        // with the host app's own post-init sync, avoiding two
        // concurrent invocations of `checkAndSyncDoctypes` /
        // `resyncMobileConfiguration` that would otherwise race.
        //
        // The splash-hang concern (wrong / unresponsive server) is
        // addressed inside [_initialMetaAndDataSync] by a short-timeout
        // permissions probe that bails fast and surfaces the failure
        // on [syncStateNotifier.value.lastError].
        await _initialMetaAndDataSync();
      }
    }
  }

  /// Runs the offline → online transition if the trigger condition is
  /// satisfied (persisted flag is `false`, residue exists). Idempotent
  /// when no transition is needed.
  ///
  /// Use from inside a widget that has the SDK reference, after the UI
  /// is mounted. [OfflineTransitionGuard] wraps this for convenience.
  Future<void> runOfflineTransitionIfPending() async {
    if (!_initialized) return;
    final persisted = await SdkMetaDao(
      _database!.rawDatabase,
    ).readOfflineMode();
    if (persisted.isPersisted &&
        !persisted.enabled &&
        await _hasResidualOfflineState()) {
      await _offlineTransitionService!.runDrainAndWipe();
    }
  }

  /// Re-run the boot-time metadata + data sync. Host apps wire this to a
  /// "Retry" action on the UI banner they show when
  /// [syncStateNotifier]'s `lastError` populates with `code == 'network'`
  /// — the only sanctioned way to retry a failed initial sync without
  /// going through full logout/login.
  ///
  /// Returns the future that completes when the boot sync settles (or
  /// fails fast on the short-timeout probe). The future never throws —
  /// failures are reported via [syncStateNotifier].
  Future<void> retryInitialMetaAndDataSync() async {
    if (!_initialized) return;
    await _initialMetaAndDataSync();
  }

  /// Resolves the session-bound offline mode from the persisted record.
  ///
  /// - Persisted value present → use it verbatim. The
  ///   persisted=online + residue case is handled by the explicit
  ///   transition flow in [_runOfflineToOnlineTransitionIfNeeded] —
  ///   this method does not stay-offline as a guard (P3 replaced the
  ///   P2 guard with the real drain/wipe path).
  /// - Unpersisted + residue on disk → assume legacy offline install,
  ///   boot offline this session (the next login persists the real value).
  /// - Unpersisted + no residue → fresh install, boot online.
  Future<OfflineMode> _resolveBootMode(OfflineMode persisted) async {
    if (persisted.isPersisted) return persisted;
    final hasResidue = await _hasResidualOfflineState();
    return OfflineMode(enabled: hasResidue, isPersisted: false);
  }

  /// Counts pending records that need to be drained before the
  /// offline → online transition can wipe local state. Used by
  /// [OfflineTransitionService] for both the trigger check and the
  /// progress UI.
  Future<int> _residueCount() async {
    if (_database == null) return 0;
    final raw = _database!.rawDatabase;
    final outboxRows = await raw.rawQuery('SELECT COUNT(*) AS c FROM outbox');
    final attachRows = await raw.rawQuery(
      'SELECT COUNT(*) AS c FROM pending_attachments',
    );
    final outboxCount = (outboxRows.first['c'] as int?) ?? 0;
    final attachCount = (attachRows.first['c'] as int?) ?? 0;
    return outboxCount + attachCount;
  }

  /// Returns true iff any of the offline-only data structures contain
  /// state from a previous offline-mode session.
  Future<bool> _hasResidualOfflineState() async {
    if (_database == null) return false;
    final raw = _database!.rawDatabase;

    final tableRows = await raw.rawQuery(
      "SELECT name FROM sqlite_master "
      "WHERE type='table' AND name LIKE 'docs\\_\\_%' ESCAPE '\\' LIMIT 1",
    );
    if (tableRows.isNotEmpty) return true;

    final outboxRows = await raw.rawQuery('SELECT 1 FROM outbox LIMIT 1');
    if (outboxRows.isNotEmpty) return true;

    final attachRows = await raw.rawQuery(
      'SELECT 1 FROM pending_attachments LIMIT 1',
    );
    if (attachRows.isNotEmpty) return true;

    return false;
  }

  @visibleForTesting
  Future<bool> hasResidualOfflineStateForTesting() =>
      _hasResidualOfflineState();

  @visibleForTesting
  Future<OfflineMode> resolveBootModeForTesting(OfflineMode persisted) =>
      _resolveBootMode(persisted);

  /// Login with username and password (stateless, returns user info)
  Future<Map<String, dynamic>> login(String username, String password) async {
    if (!_initialized) await initialize();
    final response = await _authService!.login(username, password);
    await _permissionService!.saveFromLoginResponse(response['permissions']);
    final lang = response['language'] as String?;
    if (lang != null && lang.isNotEmpty) {
      await _translationService?.setLocale(lang);
    }
    _setSessionUserFromLoginResponse(response);
    await _persistOfflineFlagFromLogin(response);
    // _initialMetaAndDataSync awaits refreshAll() internally — translations
    // for all enabled languages are persisted to SQLite before the Syncing
    // indicator clears. No separate refreshAllAsync needed here.
    unawaited(_initialMetaAndDataSync());
    return response;
  }

  /// Send OTP to mobile number for login. Returns response (e.g. tmp_id).
  Future<Map<String, dynamic>> sendLoginOtp(String mobileNo) async {
    if (!_initialized) await initialize();
    return await _authService!.sendLoginOtp(mobileNo);
  }

  /// Verify OTP and complete login. Returns same shape as [login].
  Future<Map<String, dynamic>> verifyLoginOtp(String tmpId, String otp) async {
    if (!_initialized) await initialize();
    final response = await _authService!.verifyLoginOtp(tmpId, otp);
    await _permissionService!.saveFromLoginResponse(response['permissions']);
    final lang = response['language'] as String?;
    if (lang != null && lang.isNotEmpty) {
      await _translationService?.setLocale(lang);
    }
    _setSessionUserFromLoginResponse(response);
    await _persistOfflineFlagFromLogin(response);
    // See login() — full meta sync runs unconditionally so online mode
    // also gets fresh field definitions / configuration.
    unawaited(_initialMetaAndDataSync());
    return response;
  }

  /// Persist a login response obtained OUTSIDE the SDK (a custom SSO /
  /// `mobile_login` endpoint) into a full SDK session — token -> `auth_tokens`,
  /// [SessionUser] -> `sdk_meta`, `offline_enabled`, permissions, locale.
  /// Use this when the host authenticates through a non-standard endpoint but
  /// still wants a real SDK session, so [initialize] with `autoRestoreAndSync`
  /// rehydrates it on cold start (no re-login). Mirrors [login]'s post-response
  /// bookkeeping but does NOT kick the initial sync — the caller MUST drive it,
  /// otherwise the closure/upgrade pull is suppressed here (see
  /// [_persistOfflineFlagFromLogin]) and never fires, leaving `docs__*` helper
  /// tables empty until the next `autoRestoreAndSync` cold start. Drive it by
  /// awaiting [retryInitialMetaAndDataSync] (which runs the full meta+data sync
  /// AND the upgrade closure pull after hydrating mobile-form metas). Do NOT use
  /// [forcePullAll] as a substitute — it excludes entry-point doctypes, so it
  /// reports success while the form-entry data was never pulled.
  Future<Map<String, dynamic>> persistExternalLogin(
    Map<String, dynamic> response,
  ) async {
    if (!_initialized) await initialize();
    await _authService!.persistExternalLoginResponse(response);
    await _permissionService!.saveFromLoginResponse(response['permissions']);
    final lang = response['language'] as String?;
    if (lang != null && lang.isNotEmpty) {
      await _translationService?.setLocale(lang);
    }
    _setSessionUserFromLoginResponse(response);
    await _persistOfflineFlagFromLogin(response);
    // Belt-and-suspenders: pull the AUTHORITATIVE full permission set
    // (mobile_auth.permissions) so an external/SSO login that carried only a
    // subset — or a quirky Check-flag shape — is normalised right after login.
    // Online-gated + non-fatal; the login-response permissions are already
    // persisted (and correctly coerced) above.
    await _refreshPermissionsBestEffort();
    return response;
  }

  /// Best-effort authoritative permission refresh: pulls the full set from
  /// `mobile_auth.permissions` and full-replaces the local cache. Online-gated
  /// and non-fatal — a failure never blocks login or pull-to-refresh, since the
  /// login-response permissions are already persisted by [saveFromLoginResponse].
  Future<void> _refreshPermissionsBestEffort() async {
    final ps = _permissionService;
    if (ps == null) return;
    try {
      final onlineCheck = _isOnlineOverrideForTesting ?? _syncService?.isOnline;
      if (onlineCheck == null || !await onlineCheck()) return;
      await ps.syncFromApi(timeout: const Duration(seconds: 10));
    } catch (e, st) {
      sdkLog('FrappeSDK: best-effort permission refresh failed — $e\n$st');
    }
  }

  /// Login with API key
  Future<bool> loginWithApiKey(String apiKey, String apiSecret) async {
    if (!_initialized) await initialize();
    final ok = await _authService!.loginWithApiKey(apiKey, apiSecret);
    if (ok) await _fetchUserInfoAndApply();
    return ok;
  }

  /// Prepare OAuth login: returns authorize_url and code_verifier. Open URL in browser/WebView; capture redirect with ?code=... then call loginWithOAuth.
  Future<Map<String, String>> prepareOAuthLogin({
    required String clientId,
    required String redirectUri,
    String scope = 'openid all',
    String? state,
  }) async {
    if (!_initialized) await initialize();
    return AuthService.prepareOAuthLogin(
      baseUrl: baseUrl,
      clientId: clientId,
      redirectUri: redirectUri,
      scope: scope,
      state: state,
    );
  }

  /// Login via Frappe OAuth 2.0 (authorization code + PKCE). Call after user authorizes and you have the code from redirect.
  Future<bool> loginWithOAuth({
    required String code,
    required String codeVerifier,
    required String clientId,
    required String redirectUri,
  }) async {
    if (!_initialized) await initialize();
    final ok = await _authService!.loginWithOAuth(
      code: code,
      codeVerifier: codeVerifier,
      clientId: clientId,
      redirectUri: redirectUri,
    );
    if (ok) await _fetchUserInfoAndApply();
    return ok;
  }

  /// Logout and fully wipe local DB state. Set [clearDatabase] = false to
  /// keep every table untouched (e.g. when the caller drives its own teardown).
  ///
  /// **Full nuke:** drops every application-owned table — including
  /// `doctype_meta` and `sdk_meta` — and rebuilds the base schema from
  /// scratch via [AppDatabase.clearAllData]. The next login re-fetches all
  /// metas from the server, so a different user logging in starts from a
  /// truly clean slate (no leftover field JSON, no leftover cursors, no
  /// leftover offline-mode flag).
  ///
  /// Trade-off: post-logout login takes longer because every doctype meta
  /// must round-trip to the server again. The previous targeted wipe
  /// preserved `doctype_meta.metaJson` to avoid this — but that left
  /// stale rows around when users switched accounts on a shared device,
  /// which made debugging permission/closure issues painful.
  ///
  /// Per-doctype `docs__*` tables are recreated lazily on the next pull
  /// via [OfflineRepository.ensureSchemaForClosure].
  ///
  /// In-memory caches that mirror DB state are also cleared so a returning
  /// user (or different user) doesn't hit stale-cache bugs — e.g.
  /// `_ensurePerDoctypeTable` short-circuiting against a cache that still
  /// remembers a table that was just dropped.
  Future<void> logout({bool clearDatabase = true}) async {
    if (!_initialized) {
      throw StateError(
        'Cannot logout: SDK not initialized. Call initialize() first.',
      );
    }
    // Protect clearAllData() from racing an in-flight push or pull —
    // protect() queues this behind any held SyncMutex so no push writes hit
    // a table that gets dropped mid-write.
    await _syncService!.protect(() async {
      await _authService!.logout(clearDatabase: clearDatabase);
    });
    if (clearDatabase) {
      // Wipe the translation SQLite cache and in-memory map so a different
      // user logging in on the same device doesn't see stale translations.
      await _translationService?.clearAll();
      // Cached and staged media must not outlive the data they belong to. The
      // DB wipe drops `media_cache` and `pending_attachments`, but the FILES
      // live outside SQLite, so without this the previous user's private survey
      // photos stay readable on a shared device after the next sign-in.
      //
      // Destructive by design: this also clears `outbox/`, which holds the only
      // copy of any attachment that never uploaded.
      await MediaStore.clearAll();
      // In-memory mirrors of the now-dropped DB state. Without these, the
      // next session would short-circuit table-existence checks against a
      // cache that still remembers tables that no longer exist.
      _repository?.invalidateMetaCache();
      _metaService?.clearCache();
      _modeNotifier?.value = const OfflineMode(
        enabled: false,
        isPersisted: false,
      );
    }
    // The notifier outlives session boundaries; drop a stale boot-sync
    // banner so the next login doesn't inherit the previous session's
    // unreachable-server state.
    _syncStateNotifier?.clearLastError();
  }

  /// On-device attachment media usage: staged bytes, cached bytes, and how much
  /// [sweepOrphanedMedia] would reclaim right now.
  ///
  /// Exists so a host can show usage and offer a manual "Clear cached media"
  /// control while automatic eviction is still unbuilt (Phase 2).
  ///
  /// Read-only. `orphanBytes` is a subset of `outboxBytes` and is excluded from
  /// `totalBytes`, so a UI can show "1.4 GB — 240 MB reclaimable" without
  /// double-counting. Returns zeros when the SDK is not initialized.
  Future<MediaStoreUsage> mediaStoreUsage() async {
    final refs = await _referencedStagedPaths();
    if (refs == null) {
      return const MediaStoreUsage(
        outboxBytes: 0,
        cacheBytes: 0,
        orphanBytes: 0,
        orphanCount: 0,
      );
    }
    return MediaStore.usage(refs);
  }

  /// Deletes staged attachment files that nothing references, returning the
  /// bytes reclaimed.
  ///
  /// SAFE: a file goes only when no queued attachment references it AND it was
  /// not staged in this session, so a pick sitting in an open form is never
  /// touched. Never throws.
  ///
  /// Deletes nothing if the referenced-set query fails — an empty result must
  /// never be mistaken for "everything is an orphan".
  Future<int> sweepOrphanedMedia() async {
    final refs = await _referencedStagedPaths();
    if (refs == null) return 0;
    return MediaStore.sweepOrphans(refs);
  }

  /// Paths referenced by queued attachments, or NULL when the query failed.
  ///
  /// The null is load-bearing: callers must not treat it as an empty set, which
  /// would classify every staged file as reclaimable.
  Future<Set<String>?> _referencedStagedPaths() async {
    final db = _database;
    if (db == null) return null;
    try {
      return await PendingAttachmentDao(db.rawDatabase).referencedLocalPaths();
    } catch (e, st) {
      sdkLog(
        'FrappeSDK: referenced-path query failed, skipping reclaim — $e\n$st',
      );
      return null;
    }
  }

  /// Clears the on-device media CACHE: the `cache/` directory and its index.
  ///
  /// SAFE. It never touches `outbox/` or `pending_attachments`, so an
  /// attachment that has not uploaded yet cannot be lost — cached bytes are a
  /// performance copy of server media and are always re-fetchable. This is the
  /// method to wire to a host-facing "Clear cached media" control.
  ///
  /// Only `logout(clearDatabase: true)` clears `outbox/`, where losing staged
  /// files is the intended security behaviour.
  Future<void> clearMediaCache() async {
    await MediaStore.clearCache();
    final db = _database;
    if (db == null) return;
    try {
      await MediaCacheDao(db.rawDatabase).deleteAll();
    } catch (e, st) {
      sdkLog('FrappeSDK.clearMediaCache: index clear failed — $e\n$st');
    }
  }

  /// Throws if [initialize] hasn't run. Called as the first line of every
  /// public service getter so the (12+) "if (!_initialized) throw ..."
  /// blocks all share one canonical message and exception type.
  void _assertInitialized() {
    if (!_initialized) {
      throw Exception('SDK not initialized. Call initialize() first.');
    }
  }

  /// Get Frappe API client (for direct API calls)
  ///
  /// Example:
  /// ```dart
  /// final client = sdk.api;
  /// await client.document.createDocument('Customer', {'name': 'Test'});
  /// ```
  FrappeClient get api {
    _assertInitialized();
    return _client!;
  }

  /// Get Auth Service
  AuthService get auth {
    _assertInitialized();
    return _authService!;
  }

  /// Get Meta Service
  MetaService get meta {
    _assertInitialized();
    return _metaService!;
  }

  /// Get Permission Service (doctype read/write/create/delete from login or mobile_auth.permissions)
  PermissionService get permissions {
    _assertInitialized();
    return _permissionService!;
  }

  /// Get Translation Service (Frappe translations via mobile_auth.get_translations).
  /// Use [TranslationService.loadTranslations] then [TranslationService.translate] or [TranslationService.call].
  TranslationService get translations {
    _assertInitialized();
    return _translationService!;
  }

  /// Get Sync Service
  SyncService get sync {
    _assertInitialized();
    return _syncService!;
  }

  /// Get the SessionUser service. Spec §6.6.
  ///
  /// The consumer wires login response → [SessionUser] via this service:
  /// `FrappeSDK.instance.sessionUserService.set(SessionUser.fromJson(loginResponse))`
  /// after a successful auth call. Logout flows call `.clear()` before
  /// running [AtomicWipe.wipe] to drop the persisted JSON.
  SessionUserService get sessionUserService {
    _assertInitialized();
    return _sessionUserService!;
  }

  /// Convenience: current logged-in user, or null if no session has
  /// been populated yet (e.g. fresh install before login).
  SessionUser? get sessionUser => _sessionUserService?.current;

  /// Convenience: stream of [SessionUser] changes — fires on `set()` and
  /// `clear()`. Restored state from disk does NOT fire (use the synchronous
  /// [sessionUser] getter for the initial read).
  Stream<SessionUser?>? get sessionUser$ => _sessionUserService?.stream;

  /// Get Repository (for offline operations)
  OfflineRepository get repository {
    _assertInitialized();
    return _repository!;
  }

  /// Single canonical read path for list and count queries. Branches on
  /// the session-bound [OfflineMode] under the hood:
  /// - offline → per-doctype `docs__<doctype>` tables via FilterParser
  /// - online → `frappe.client.get_list` / `frappe.client.get_count`
  UnifiedResolver get resolver {
    _assertInitialized();
    return _resolver!;
  }

  /// Get the offline → online transition service.
  ///
  /// Subscribers listen on [OfflineTransitionService.stream] to react
  /// to drain progress, drain failures, and the wipe step. Consumer
  /// apps mount [OfflineTransitionScreen] above their router driven by
  /// this stream. Spec §7.
  OfflineTransitionService get offlineTransition {
    _assertInitialized();
    return _offlineTransitionService!;
  }

  /// Get Link Option Service
  LinkOptionService get linkOptions {
    _assertInitialized();
    return _linkOptionService!;
  }

  /// Get Database instance
  AppDatabase get database {
    _assertInitialized();
    return _database!;
  }

  /// Imperative sync surface backing the sync error UI: `pendingErrors`,
  /// `retry(outboxId)`, `retryAll`, `retryPaused(outboxId)`, `resolveConflict`. Returns `null`
  /// when the SDK was bootstrapped without an outbox-backed sync engine
  /// (e.g. some test seams) so call sites can render a static banner
  /// without retry affordances.
  SyncController? get syncController => _syncController;

  /// Check if authenticated
  bool get isAuthenticated => _authService?.isAuthenticated ?? false;

  /// Roles for the currently authenticated user (if provided by backend).
  List<String> get roles => _authService?.roles ?? const [];

  /// Returns the current authenticated user's info, or null.
  ({String email, String fullName})? get currentUser =>
      _authService?.currentUserInfo;

  /// Stable UUID for this device/install. Use when creating docs from
  /// mobile so server can set mobile_uuid. Memoised — secure storage is
  /// read at most once per SDK instance (initial read happens during
  /// [_doInitialize]).
  Future<String> getMobileUuid() async {
    if (!_initialized) await initialize();
    return _resolveMobileUuid();
  }

  /// Internal helper used by every per-push / per-link-options lambda.
  /// Returns the cached uuid synchronously when available, falling back
  /// to a live secure-storage read if init hasn't populated the cache yet
  /// (e.g. in test seams that bypass [_doInitialize]).
  Future<String> _resolveMobileUuid() async {
    final cached = _mobileUuid;
    if (cached != null && cached.isNotEmpty) return cached;
    final fresh = await _authService!.getOrCreateMobileUuid();
    _mobileUuid = fresh;
    return fresh;
  }

  /// Prefetch metadata for mobile form doctypes into DB only (no in-memory cache).
  /// Use this at app start; meta is loaded into cache only when getMeta(doctype) is used.
  Future<void> loadMetadata() async {
    if (!_initialized) await initialize();
    await _metaService!.prefetchMobileFormDoctypes();
  }

  /// Sync all mobile form doctypes
  Future<void> syncAll() async {
    if (!_initialized) await initialize();
    await _metaService!.syncAllMobileFormDoctypes();
  }

  /// Check and sync doctypes from login response on app launch.
  ///
  /// Compares timestamps from mobile_form_names with stored doctype meta
  /// and syncs any that have been updated or are new.
  Future<void> checkAndSyncDoctypes() async {
    if (!_initialized) await initialize();
    await _metaService!.checkAndSyncDoctypes();
  }

  /// Resync mobile configuration from server.
  ///
  /// Calls `mobile_auth.configuration` API to fetch updated mobile form list
  /// and syncs doctype metadata for any doctypes that have been updated or are new.
  ///
  /// Throws if not authenticated or API call fails.
  Future<void> resyncMobileConfiguration() async {
    if (!_initialized) await initialize();
    await _metaService!.resyncMobileConfiguration();
  }

  /// After OAuth/API key login: fetch user info (mobile_auth.me) and apply permissions + locale.
  Future<void> _fetchUserInfoAndApply() async {
    final userInfo = await _authService!.fetchUserInfo();
    if (userInfo == null) return;
    await _permissionService!.saveFromLoginResponse(userInfo['permissions']);
    final lang = userInfo['language'] as String?;
    if (lang != null && lang.isNotEmpty) {
      await _translationService?.setLocale(lang);
    }
    await _persistOfflineFlagFromLogin(userInfo);
    // See login() — full meta sync runs unconditionally so online mode
    // also gets fresh field definitions / configuration.
    unawaited(_initialMetaAndDataSync());
    // mobile_auth.me returns a Frappe user document — 'name' is the user email.
    final name = userInfo['name'] as String?;
    if (name != null && name.isNotEmpty) {
      await _sessionUserService?.set(
        SessionUser(
          name: name,
          fullName: userInfo['full_name'] as String?,
          userImage: userInfo['user_image'] as String?,
          roles: ((userInfo['roles'] as List?) ?? [])
              .map((r) => r.toString())
              .where((r) => r.isNotEmpty)
              .toList(),
          userDefaults: ((userInfo['user_defaults'] as Map?) ?? {}).map(
            (k, v) => MapEntry(k.toString(), v.toString()),
          ),
          permissions: {},
          extras: {},
        ),
      );
    }
  }

  Future<void> _persistOfflineFlagFromLogin(
    Map<String, dynamic> response,
  ) async {
    final incoming = response['offline_enabled'] == true;
    // login() always fires `unawaited(_initialMetaAndDataSync())` immediately
    // after this. That path is the right place to run `_runUpgradeClosurePull`
    // because it first does `checkAndSyncDoctypes` + `resyncMobileConfiguration`,
    // which (re)hydrate the mobile-form list and entry-point `metaJson` rows.
    //
    // If we let `_applyOfflineFlag` fire its own unawaited closure pull here,
    // it races: the parallel pull starts BEFORE meta hydration completes, so
    // `closure()` reads stale/empty `doctype_meta` rows, can't expand to Link
    // targets, grabs the `SyncMutex`, and pulls only entry points. The
    // hydrated second closure pull (and SNF's own `pullSyncMany`) then both
    // see "Sync already in progress" and short-circuit — leaving every helper
    // doctype (State, District, Block, Village, …) unpulled offline.
    //
    // Suppress here; the post-login `_initialMetaAndDataSync` covers it.
    await _applyOfflineFlag(incoming, triggerUpgradePull: false);
  }

  /// Persists the new offline-mode flag and dispatches a mid-session
  /// transition when direction changes:
  ///
  /// - false → true: notifier flips, then [_runUpgradeClosurePull]
  ///   fires unawaited so this launch's `docs__*` tables get populated
  ///   without an app restart.
  /// - true → false: notifier flips, then
  ///   [OfflineTransitionService.runDrainAndWipe] fires unawaited; the
  ///   consumer's [OfflineTransitionGuard] (subscribed to the service
  ///   stream) shows progress / drain-failed UI as needed.
  /// - no change: persists `isPersisted=true` and returns.
  ///
  /// Persist failures (DB closed, etc.) are logged and swallowed; the
  /// notifier is not flipped and no transition fires when persistence
  /// failed, keeping session state and `sdk_meta` aligned.
  Future<void> _applyOfflineFlag(
    bool incoming, {
    bool triggerUpgradePull = true,
  }) async {
    if (_database == null || _modeNotifier == null) return;

    try {
      await SdkMetaDao(_database!.rawDatabase).writeOfflineMode(
        enabled: incoming,
        setAtMs: DateTime.now().millisecondsSinceEpoch,
      );
    } catch (e, st) {
      sdkLog('FrappeSDK: failed to persist offline_enabled — $e\n$st');
      return;
    }

    final previous = _modeNotifier!.value;
    final next = OfflineMode(enabled: incoming, isPersisted: true);

    // No direction change: sync isPersisted=true and exit.
    if (previous.enabled == next.enabled) {
      _modeNotifier!.value = next;
      return;
    }

    // Direction changed — flip notifier first so any concurrent service
    // call after this point sees the new mode.
    _modeNotifier!.value = next;

    if (next.enabled) {
      // false → true mid-session: kick the closure pull so this launch's
      // `docs__*` tables get populated without an app restart. Suppressed
      // when called from the login path (`_persistOfflineFlagFromLogin`
      // passes `triggerUpgradePull: false`), because login() already
      // fires `_initialMetaAndDataSync` which runs the same upgrade pull
      // *after* hydrating mobile-form metas — firing both races, with
      // the parallel one seeing stale `doctype_meta` rows and pulling
      // only entry points before the SyncMutex blocks the hydrated one.
      if (triggerUpgradePull) {
        unawaited(_runUpgradeClosurePull());
      }
    } else {
      // true → false: drain outbox + wipe docs__* tables. The existing
      // OfflineTransitionGuard subscribes to the stream and presents
      // progress / drain-failed UI.
      final transition = _offlineTransitionService;
      if (transition != null) {
        unawaited(transition.runDrainAndWipe());
      }
    }
  }

  @visibleForTesting
  Future<void> persistOfflineFlagFromLoginForTesting(
    Map<String, dynamic> response,
  ) => _persistOfflineFlagFromLogin(response);

  /// Builds a [SessionUser] from a login/OTP response and persists it.
  /// The login response uses `user` (not `name`) for the username.
  void _setSessionUserFromLoginResponse(Map<String, dynamic> response) {
    final name = response['user'] as String?;
    if (name == null || name.isEmpty) return;
    _sessionUserService?.set(
      SessionUser(
        name: name,
        fullName: response['full_name'] as String?,
        roles: ((response['roles'] as List?) ?? [])
            .map((r) => r.toString())
            .where((r) => r.isNotEmpty)
            .toList(),
        userDefaults: {},
        permissions: {},
        extras: {},
      ),
    );
  }

  /// Internal: initial metadata + data sync for mobile doctypes.
  ///
  /// 1) Sync doctypes from login mobile_form_names (checkAndSyncDoctypes)
  /// 2) Resync configuration from server (mobile_auth.configuration)
  /// 3) Pull records for all mobile doctypes into the offline DB
  /// Guarded entry point: concurrent callers join the single in-flight run
  /// instead of starting a parallel meta/data sync (PR#36 round-4 H5). The
  /// guard lives here — not in initialize()'s [_initInFlight] — because
  /// login()/verifyLoginOtp() reach the body directly, bypassing initialize().
  Future<void> _initialMetaAndDataSync() {
    final inFlight = _metaSyncInFlight;
    if (inFlight != null) return inFlight.future;
    final completer = Completer<void>();
    _metaSyncInFlight = completer;
    () async {
      try {
        await _runInitialMetaAndDataSync();
        completer.complete();
      } catch (e, st) {
        completer.completeError(e, st);
      } finally {
        _metaSyncInFlight = null;
      }
    }();
    return completer.future;
  }

  Future<void> _runInitialMetaAndDataSync() async {
    if (_disposed || _metaService == null || _syncService == null) return;
    // Capture the service so a concurrent [dispose] nulling the field mid-flight
    // cannot turn a later `!` deref into an NPE. dispose() does not close the
    // AppDatabase singleton, so the captured service stays operable; the
    // [_disposed] checkpoints below stop us doing pointless post-teardown work.
    final meta = _metaService!;

    // Offline launch: every call below is pure-network and would block
    // on the HTTP timeout (~30s each, ~4 minutes total) before failing.
    // `_cachedOnline` was set during initialize() so reading it here is
    // race-free.
    if (!_cachedOnline) return;

    // Clear any prior boot error so the host UI can drop a stale banner
    // before we probe again.
    _syncStateNotifier?.clearLastError();

    // Flip `isInitialSync: true` for the whole boot/login data-pull so
    // any host UI subscribed to `state$` (SyncStatusBar, custom banners)
    // can render a "Syncing…" indicator while the closure pull runs.
    // The flag is reset by [_setInitialSyncFlag] at every exit point
    // below so it never sticks across early returns or thrown errors.
    final initialSyncNotifier = _syncStateNotifier;
    _setInitialSyncFlag(initialSyncNotifier, true);

    try {
      // Short-timeout probe: if the configured base URL is wrong or the
      // server is down, this fails in ~10s instead of ~93s. Bailing here
      // also skips the long-timeout downstream calls (meta, config,
      // closure pull) that would chain another ~90s wait each.
      await _permissionService?.syncFromApi(
        timeout: const Duration(seconds: 10),
      );
    } on NetworkException catch (e, st) {
      _syncStateNotifier?.recordLastError(
        SyncErrorSummary(
          code: 'network',
          message: e.message,
          at: DateTime.now(),
        ),
      );
      sdkLog('FrappeSDK: boot sync — server unreachable: $e\n$st');
      _setInitialSyncFlag(initialSyncNotifier, false);
      return;
    } catch (e, st) {
      _syncStateNotifier?.recordLastError(
        SyncErrorSummary(
          code: 'permissions',
          message: e.toString(),
          at: DateTime.now(),
        ),
      );
      sdkLog('FrappeSDK: permissions.syncFromApi failed — $e\n$st');
      // Non-network failure: continue with other steps so a partial
      // outage (e.g. one method 500) doesn't block the rest of boot.
    }

    // Await translations for ALL enabled languages so the SQLite cache is
    // fully populated before the "Syncing…" indicator clears.  Errors per
    // language are swallowed inside refreshAll() — a failing language never
    // aborts meta sync.
    try {
      await _translationService?.refreshAll();
    } catch (e, st) {
      sdkLog('FrappeSDK: translation refresh failed — $e\n$st');
    }

    // The SDK may have been disposed during the network awaits above; bail
    // before doing further work. (Do not touch the now-closed sync notifier.)
    if (_disposed) return;

    try {
      await meta.checkAndSyncDoctypes();
    } catch (e, st) {
      sdkLog('FrappeSDK: meta.checkAndSyncDoctypes failed — $e\n$st');
    }

    if (_disposed) return;

    try {
      await meta.resyncMobileConfiguration();
    } catch (e, st) {
      sdkLog('FrappeSDK: meta.resyncMobileConfiguration failed — $e\n$st');
    }

    // Online mode stops here — closure pull is offline-only.
    if (!_offlineMode.enabled) {
      _setInitialSyncFlag(initialSyncNotifier, false);
      return;
    }

    try {
      await _runUpgradeClosurePull();
    } finally {
      _setInitialSyncFlag(initialSyncNotifier, false);
    }
  }

  /// Toggles [SyncState.isInitialSync] when [notifier] is non-null. Used
  /// by [_initialMetaAndDataSync] to bracket the first-pull window so any
  /// host UI subscribed to `state$` can render a "Syncing…" indicator
  /// without leaking the flag across early-return paths.
  void _setInitialSyncFlag(SyncStateNotifier? notifier, bool value) {
    if (notifier == null) return;
    notifier.value = notifier.value.copyWith(isInitialSync: value);
  }

  /// Pulls every doctype in the closure of the user's mobile-form entry
  /// points, skipping child doctypes (they ride along inside parents) and
  /// doctypes the user can't read.
  ///
  /// Idempotent — pull cursors mean re-running is cheap. Per-doctype
  /// failures are logged and skipped. Used by both [_initialMetaAndDataSync]
  /// (initial returning-user sync) and [_applyOfflineFlag] (mid-session
  /// upgrade after the offline_enabled flag flips false → true).
  /// Returns the set of doctypes deferred by SIG-2 (push was active during
  /// pull). Callers that care (SyncController) re-pull those doctypes after
  /// push completes.
  Future<Set<String>> _runUpgradeClosurePull() async {
    // Capture every field this pull touches so a concurrent [dispose] nulling
    // them mid-pull cannot NPE the derefs below. The AppDatabase singleton is
    // not closed by dispose, so the captured services remain usable.
    final meta = _metaService;
    final sync = _syncService;
    final db = _database;
    final pullEngine = _pullEngine;
    final client = _client;
    if (_disposed ||
        meta == null ||
        sync == null ||
        db == null ||
        pullEngine == null ||
        client == null) {
      return const <String>{};
    }
    final repository = _repository;
    // Block on any pending offline→online drain — its wipe phase drops
    // every `docs__*` table, which would clobber rows this pull is
    // about to insert. In the normal trigger path the offline-mode
    // gate in [_initialMetaAndDataSync] short-circuits before we ever
    // get here, so this await is a defensive belt-and-braces.
    final drain = _pendingDrain;
    if (drain != null) {
      try {
        await drain;
      } catch (e, st) {
        // Drain failure is surfaced via the transition stream; we just
        // need to know it has settled before writing to per-doctype tables.
        // Log so the failure mode is visible at the boot path too.
        sdkLog('FrappeSDK: pending drain awaited with error — $e\n$st');
      }
    }
    try {
      final onlineCheck = _isOnlineOverrideForTesting ?? sync.isOnline;
      if (!await onlineCheck()) return const <String>{};
      final entryPoints = await meta.getMobileFormDoctypeNames();
      final closure = await meta.closure(entryPoints);

      // Create per-doctype mirror tables BEFORE the pull writes into them.
      // Without this, PullEngine.applyPageInTxn crashes with
      // `no such table: docs__<doctype>` for any doctype whose schema
      // hasn't been created yet (the per-doctype table create path is
      // owned by saveDocument / ensureSchemaForClosure — neither of which
      // ran during the SDK's auto-fired initial sync before this fix).
      // SNF's own runSnfPostSdkSync also calls ensureSchemaForClosure as
      // belt-and-suspenders; this call is idempotent.
      if (repository != null) {
        final metasByDoctype = <String, DocTypeMeta>{};
        for (final dt in closure.doctypes) {
          try {
            metasByDoctype[dt] = await meta.getMeta(dt);
          } catch (e, st) {
            sdkLog('FrappeSDK: closure pull — getMeta($dt) failed — $e\n$st');
          }
        }
        try {
          await repository.ensureSchemaForClosure(
            metas: metasByDoctype,
            childDoctypes: closure.childDoctypes,
          );
        } catch (e, st) {
          sdkLog(
            'FrappeSDK: closure pull — ensureSchemaForClosure failed — $e\n$st',
          );
        }
      }

      final pullable = await _buildPullableDoctypes(
        entryPoints: entryPoints,
        closure: closure,
      );
      if (pullable.isEmpty) return const <String>{};

      // #49 pre-flight: ask the server which INCREMENTAL doctypes actually
      // changed, and skip pulling the rest. Only doctypes with a complete
      // (delta-ready) cursor are eligible — INITIAL/RESUME doctypes have no
      // trustworthy watermark and are always pulled. Any failure (missing
      // endpoint, network) leaves `allowed == pullable` → full pull.
      var allowed = pullable.toSet();
      final eligible = <String, String>{}; // doctype -> since (cursor.modified)
      for (final dt in pullable) {
        try {
          final raw = await db.doctypeMetaDao.getLastOkCursor(dt);
          if (raw == null || raw.isEmpty) continue;
          final cursor = Cursor.fromJson(
            jsonDecode(raw) as Map<String, dynamic>,
          );
          if (cursor.complete && cursor.modified != null) {
            eligible[dt] = cursor.modified!;
          }
          // TODO(#13): zero-row completed doctypes skip the cursor.modified
          // filter and are re-pulled each cycle — needs a separate zero-row
          // sentinel. A doctype whose last sync completed successfully but
          // returned 0 rows has cursor.complete==true and cursor.modified==null,
          // so it falls through the guard above and is re-included in every
          // incremental cycle. Adding the sentinel requires a new cursor field
          // (e.g. `zeroRowAt`) and a read in the eligibility filter here.
        } catch (e, st) {
          sdkLog('FrappeSDK: sync_details cursor read($dt) failed — $e\n$st');
        }
      }
      if (eligible.isNotEmpty) {
        final manifest = await client.doctype.getSyncDetails([
          for (final entry in eligible.entries)
            {'doctype': entry.key, 'since': entry.value},
        ]);
        if (manifest != null) {
          final skip = doctypesToSkip(eligible.keys.toSet(), manifest);
          if (skip.isNotEmpty) {
            allowed = allowed.difference(skip);
            sdkLog(
              'FrappeSDK: sync_details skipped ${skip.length}/'
              '${eligible.length} unchanged doctypes',
            );
          }
        }
      }

      // Hold the SyncMutex for the entire closure pull so concurrent
      // single-doctype callers (pullSync, pullSyncWaiting) serialise
      // behind it — same contract as the former pullSyncMany call path.
      return await sync.protect(
        () => pullEngine.run(closure, allowedDoctypes: allowed),
      );
    } catch (e, st) {
      sdkLog('FrappeSDK: closure pull failed — $e\n$st');
      return const <String>{};
    } finally {
      _syncCompleteController?.add(null);
    }
  }

  /// Builds the set of doctypes eligible for a closure pull, given the
  /// already-resolved [closure] from `MetaService.closure(entryPoints)`.
  /// Always excludes child-table doctypes (those ride inside parents)
  /// and any doctype the user lacks read permission for. When
  /// [excludeEntryPoints] is true, entry-point mobile-form doctypes are
  /// also excluded — `forcePullAll` opts in because entry points are
  /// managed by the normal sync cycle there; `_runUpgradeClosurePull`
  /// opts out because the upgrade pull is its only sync trigger.
  ///
  /// Returns a `List<String>` rather than a `Set` because callers want
  /// the cursor-clear pre-pass (`forcePullAll`) to iterate deterministically
  /// and the closure pull (`_runUpgradeClosurePull`) accepts any iterable.
  Future<List<String>> _buildPullableDoctypes({
    required Iterable<String> entryPoints,
    required ClosureResult closure,
    bool excludeEntryPoints = false,
  }) async {
    final entryPointSet = excludeEntryPoints ? entryPoints.toSet() : null;
    final pullable = <String>[];
    for (final doctype in closure.doctypes) {
      if (entryPointSet != null && entryPointSet.contains(doctype)) continue;
      if (closure.childDoctypes.contains(doctype)) continue;
      // NOTE: do NOT gate the closure pull on client-side canRead. The closure
      // is exactly the set of doctypes the mobile forms need offline (entry
      // points + their Link/Table targets). The backend decouples the
      // mobile-form list from the DocPerm list, so reference masters (Gender,
      // Language, Country, …) can carry an explicit can_read=0 yet are required
      // for link pickers — gating here left them empty offline. The server still
      // enforces real read permission on each pull; a genuinely forbidden
      // doctype simply returns empty/403 (caught per-doctype) instead of
      // starving every offline picker.
      pullable.add(doctype);
    }
    return pullable;
  }

  /// Adapter for `SyncController.runPull`. Propagates the SIG-2 deferred set
  /// from PullEngine so SyncController can re-pull those doctypes after push.
  Future<Set<String>> _runPullForController() => _runUpgradeClosurePull();

  /// Adapter for `SyncController.runPullForDoctypes`. Routes a targeted
  /// re-pull through `SyncService.pullSyncMany` for SIG-2 deferred doctypes
  /// after push completes.
  Future<void> _runPullForDoctypesViaController(Set<String> doctypes) async {
    if (doctypes.isEmpty) return;
    await _syncService?.pullSyncMany(doctypes: doctypes.toList());
  }

  @visibleForTesting
  Future<Set<String>> runUpgradeClosurePullForTesting() =>
      _runUpgradeClosurePull();

  @visibleForTesting
  void injectPullEngineForTesting(PullEngine engine) {
    _pullEngine = engine;
  }

  @visibleForTesting
  void overrideIsOnlineForTesting(Future<bool> Function() fn) {
    _isOnlineOverrideForTesting = fn;
  }

  /// Re-pulls every helper, master, and reference doctype in the closure from
  /// scratch by clearing their pull cursors first. Entry-point mobile-form
  /// doctypes and child-table doctypes are excluded — entry-points are managed
  /// by the normal sync cycle; child tables ride along inside their parents.
  ///
  /// Because of that exclusion this is the WRONG method for remediating stale
  /// entry-point data (e.g. backfilling the schema-v6 audit columns): it reports
  /// success while the form-entry doctypes were never re-pulled. Use
  /// [forceFullRepull] for that.
  ///
  /// No-ops silently if the SDK isn't initialized (`_metaService`,
  /// `_syncService`, or `_database` is null). Per-doctype failures are logged
  /// and skipped. Emits to [syncComplete$] when finished so the home screen
  /// refreshes its counts.
  Future<void> forcePullAll() async {
    if (_metaService == null || _syncService == null || _database == null) {
      return;
    }
    try {
      // Force pull (pull-to-refresh) always reconciles permissions against the
      // authoritative endpoint. Best-effort: never blocks the data pull.
      await _refreshPermissionsBestEffort();
      final entryPoints = await _metaService!.getMobileFormDoctypeNames();
      final closure = await _metaService!.closure(entryPoints);
      final pullable = await _buildPullableDoctypes(
        entryPoints: entryPoints,
        closure: closure,
        excludeEntryPoints: true,
      );
      if (pullable.isEmpty) {
        _syncCompleteController?.add(null);
        return;
      }
      // Cursor reset must happen before the parallel batch so each worker
      // reads a freshly-cleared cursor and re-fetches the entire dataset.
      // Cheap (one UPDATE per doctype) so a sequential pre-pass is fine.
      final dao = _database!.doctypeMetaDao;
      for (final doctype in pullable) {
        try {
          await dao.clearLastOkCursor(doctype);
        } catch (e, st) {
          sdkLog(
            'FrappeSDK: forcePullAll cursor-clear($doctype) failed — $e\n$st',
          );
        }
      }
      final results = await _syncService!.pullSyncMany(doctypes: pullable);
      for (final entry in results.entries) {
        final err = entry.value.error;
        if (err != null && err.isNotEmpty) {
          sdkLog('FrappeSDK: forcePullAll(${entry.key}) failed — $err');
        }
      }
    } catch (e, st) {
      sdkLog('FrappeSDK: forcePullAll failed — $e\n$st');
    }
    _syncCompleteController?.add(null);
  }

  /// Re-pulls the closure from scratch, INCLUDING entry-point mobile-form
  /// doctypes by default — the one difference from [forcePullAll], and the whole
  /// reason this exists.
  ///
  /// Use this when a change makes previously-pulled rows stale in a way an
  /// incremental pull cannot repair. The motivating case is the schema-v6 audit
  /// columns (`owner` / `creation` / `modified_by`): they are server-owned, so a
  /// row only receives them when it is re-fetched, and incremental pulls
  /// (`modified >= cursor.modified`) never re-fetch a row whose `modified` has
  /// not advanced. `owner = <me>` then silently matches only recently-touched
  /// rows.
  ///
  /// [forcePullAll] cannot serve this purpose: it excludes entry points, which
  /// are exactly the mobile-form doctypes where an `owner`-scoped filter is the
  /// point. Note the trade-off this method makes deliberately — re-draining an
  /// entry-point doctype is the heaviest pull the SDK performs. Prefer it as a
  /// one-shot remediation, not a pull-to-refresh handler.
  ///
  /// Set [includeEntryPoints] to false for [forcePullAll]'s scope with this
  /// method's explicit naming. Child-table doctypes are always excluded — they
  /// ride along inside their parents.
  ///
  /// No-ops silently if the SDK isn't initialized. Per-doctype failures are
  /// logged and skipped. Emits to [syncComplete$] when finished.
  Future<void> forceFullRepull({bool includeEntryPoints = true}) async {
    if (_metaService == null || _syncService == null || _database == null) {
      return;
    }
    try {
      await _refreshPermissionsBestEffort();
      final entryPoints = await _metaService!.getMobileFormDoctypeNames();
      final closure = await _metaService!.closure(entryPoints);
      final pullable = await _buildPullableDoctypes(
        entryPoints: entryPoints,
        closure: closure,
        excludeEntryPoints: !includeEntryPoints,
      );
      if (pullable.isEmpty) {
        _syncCompleteController?.add(null);
        return;
      }
      // Clear every cursor before the parallel batch so each worker reads a
      // freshly-cleared cursor and re-fetches the entire dataset.
      final dao = _database!.doctypeMetaDao;
      for (final doctype in pullable) {
        try {
          await dao.clearLastOkCursor(doctype);
        } catch (e, st) {
          sdkLog(
            'FrappeSDK: forceFullRepull cursor-clear($doctype) failed — $e\n$st',
          );
        }
      }
      final results = await _syncService!.pullSyncMany(doctypes: pullable);
      for (final entry in results.entries) {
        final err = entry.value.error;
        if (err != null && err.isNotEmpty) {
          sdkLog('FrappeSDK: forceFullRepull(${entry.key}) failed — $err');
        }
      }
    } catch (e, st) {
      sdkLog('FrappeSDK: forceFullRepull failed — $e\n$st');
    }
    _syncCompleteController?.add(null);
  }

  /// Releases the per-instance services this SDK owns and resets
  /// [_initialized] so a follow-up [initialize] rebuilds cleanly.
  ///
  /// Lifecycle contract:
  /// - The instance is REUSABLE after dispose — call [initialize] again.
  /// - References handed out by getters before dispose (e.g. cached
  ///   `sessionUserService`, `sessionUser$`) point at services whose
  ///   `StreamController` is closed; consumers MUST drop those refs and
  ///   re-fetch from the SDK after the next [initialize].
  /// - Calling getters between [dispose] and a fresh [initialize] throws
  ///   the same `Exception` they already raise when `!_initialized`
  ///   (e.g. `sessionUserService` getter at lines 367–371).
  /// - Idempotent — safe to call multiple times.
  /// - [AppDatabase] is a per-app process singleton (via
  ///   [AppDatabase.getInstance]); we drop our reference but never call
  ///   `close()` on it because the next [initialize] would re-use the
  ///   same underlying database handle.
  Future<void> dispose() async {
    // Signal first (before any await) so a fire-and-forget initial sync still
    // in flight bails at its next checkpoint instead of touching the services
    // and notifiers torn down below.
    _disposed = true;

    // Tear down owned services that hold StreamControllers / subscriptions
    // first, so their listeners stop firing into nulled refs below.
    await _connectivitySub?.cancel();
    await _connectivityWatcher?.dispose();
    await _sessionUserService?.dispose();
    await _offlineTransitionService?.dispose();
    await _translationService?.dispose();

    // ① Drain in-flight pull BEFORE closing the notifier it writes to.
    // _pendingDrain may hold a PullEngine.run() still calling
    // notifier.value = … on every page. Closing the notifier first causes
    // every remaining write to throw StateError on the closed StreamController.
    final pending = _pendingDrain;
    if (pending != null) {
      try {
        await pending;
      } catch (e, st) {
        sdkLog(
          'FrappeSDK.dispose: pendingDrain still failing at teardown — '
          '$e\n$st',
        );
      }
    }

    // ② Now safe to close — no pull worker is still writing to these.
    await _syncStateNotifier?.close();
    await _syncCompleteController?.close();

    // Null every per-instance ref so the GC can reclaim the dependency
    // graph (services, engines, pools, queries). AppDatabase is a process
    // singleton; we drop the ref but the handle stays open for the next
    // initialize().
    _client = null;
    _database = null;
    _authService = null;
    _metaService = null;
    _repository = null;
    _permissionService = null;
    _translationService = null;
    _syncService = null;
    _resolver = null;
    _linkOptionService = null;
    _syncController = null;
    _pushEngine = null;
    _pullEngine = null;
    _pushPool = null;
    _pullPool = null;
    _syncStateNotifier = null;
    _sessionUserService = null;
    _securityService = null;
    _offlineTransitionService = null;
    _modeNotifier = null;
    _syncCompleteController = null;
    _pendingDrain = null;
    _connectivitySub = null;
    _connectivityWatcher = null;
    _mobileUuid = null;

    _initialized = false;
  }
}

/// Concrete, `get_list`-safe column fieldnames for [meta] — used to expand a
/// wildcard `['*']` request, which this server rejects. Skips layout-only and
/// child-table field types plus virtual fields (none are real DB columns) and
/// always includes the standard document columns. `workflow_state` / `status`
/// are included automatically when present in the doctype's fields (workflow
/// doctypes).
List<String> listableFieldnamesForStar(DocTypeMeta meta) {
  const skip = <String>{
    'Section Break',
    'Column Break',
    'Tab Break',
    'HTML',
    'Button',
    'Table',
    'Table MultiSelect',
    'Fold',
    'Heading',
    // 'Image' is one of Frappe's no_value_fields and is absent from
    // data_fieldtypes, so no DB column is ever generated for it. Emitting it in
    // a ['*'] expansion sends a nonexistent column to frappe.client.get_list
    // (the exact unknown-column failure this expansion exists to avoid).
    'Image',
  };
  final out = <String>{
    'name',
    'owner',
    'creation',
    'modified',
    'modified_by',
    'docstatus',
    'idx',
  };
  for (final f in meta.fields) {
    final fn = f.fieldname;
    if (fn == null || fn.isEmpty) continue;
    // A virtual DocField (`is_virtual=1`) is computed at runtime by a property
    // setter / controller and gets NO DB column, whatever its fieldtype — so
    // the fieldtype skip set above cannot catch it. Emitting it in a ['*']
    // expansion sends a nonexistent column to frappe.client.get_list (the
    // exact unknown-column failure this expansion exists to avoid).
    if (f.isVirtual) continue;
    if (skip.contains(f.fieldtype)) continue;
    out.add(fn);
  }
  return out.toList();
}
