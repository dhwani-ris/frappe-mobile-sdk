// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// For license information, please see license.txt

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import '../api/client.dart';
import '../database/app_database.dart';
import '../database/daos/doctype_meta_dao.dart';
import '../database/daos/sdk_meta_dao.dart';
import '../database/migrations/v1_to_v2.dart';
import '../models/doc_type_meta.dart';
import '../models/offline_mode.dart';
import '../models/session_user.dart';
import '../query/unified_resolver.dart';
import '../services/auth_service.dart';
import '../services/local_writer.dart';
import '../services/meta_service.dart';
import '../services/permission_service.dart';
import '../services/session_user_service.dart';
import '../services/sync_service.dart';
import '../services/offline_repository.dart';
import '../services/offline_transition_service.dart';
import '../services/link_option_service.dart';
import '../services/translation_service.dart';

/// Thrown by [FrappeSDK.runV1ToV2MigrationIfNeeded] when the device has no
/// connectivity and the offline-first data migration cannot proceed. The
/// consumer app should display [MigrationBlockedScreen] (or its own
/// equivalent) and retry the call once connectivity is restored.
class MigrationNeedsNetworkException implements Exception {
  @override
  String toString() =>
      'v1→v2 data migration requires network connectivity. '
      'Show MigrationBlockedScreen and retry when online.';
}

/// Main SDK initialization class for easy setup
class FrappeSDK {
  final String baseUrl;
  final String? databaseAppName;

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
  SessionUserService? _sessionUserService;

  bool _initialized = false;

  /// Cached synchronous online state — updated lazily via [_defaultIsOnline].
  /// Conservative default (false) means the resolver starts in offline-only
  /// mode and switches to background-refresh mode once the first connectivity
  /// check resolves.
  bool _cachedOnline = false;

  /// Session-bound offline mode. Set in [initialize] from the persisted
  /// `sdk_meta.offline_enabled` (via [_resolveBootMode]) and immutable
  /// for the rest of the session. Forced offline in `forTesting` to keep
  /// test behaviour identical to pre-P2 builds.
  OfflineMode _offlineMode = const OfflineMode(
    enabled: true,
    isPersisted: true,
  );

  @visibleForTesting
  OfflineMode get offlineModeForTesting => _offlineMode;

  FrappeSDK({required this.baseUrl, this.databaseAppName});

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
  }) : databaseAppName = null {
    _database = database;
    _offlineMode = offlineMode;
    // Create FrappeClient directly — avoids AuthService.initialize() which
    // writes to FlutterSecureStorage and is unavailable in widget tests.
    _client = FrappeClient(baseUrl);
    // Use AuthService.forTesting so the client and database are wired up
    // without touching FlutterSecureStorage. This means sdk.auth methods
    // (e.g. getOrCreateMobileUuid, restoreSession) won't throw "not
    // initialized" if called from any production code path under test.
    _authService = AuthService.forTesting(_client!, database: database);
    _metaService = MetaService(_client!, _database!);
    final testMetaService = _metaService!;
    final testMetaFn = testMetaService.getMeta;
    final testLocalWriter = LocalWriter(database.rawDatabase, testMetaFn);
    _repository = OfflineRepository(
      _database!,
      localWriter: testLocalWriter,
      offlineMode: offlineMode,
      client: _client,
    );
    _permissionService = PermissionService(_client!, _database!);
    _translationService = TranslationService(_client!);
    _syncService = SyncService(
      _client!,
      _repository!,
      _database!,
      getMobileUuid: () async => 'test-uuid',
      offlineMode: offlineMode,
    );
    final testResolver = UnifiedResolver(
      db: database.rawDatabase,
      metaDao: DoctypeMetaDao(database.rawDatabase),
      isOnline: () => false,
      backgroundFetch: (_, _) async {},
      metaResolver: testMetaFn,
      offlineMode: offlineMode,
      client: _client,
    );
    _linkOptionService = LinkOptionService(testResolver, testMetaFn);
    _offlineTransitionService = OfflineTransitionService(
      database: _database!,
      drainSyncFactory: () async => SyncService(
        _client!,
        _repository!,
        _database!,
        getMobileUuid: () async => 'test-uuid',
        offlineMode: const OfflineMode(enabled: true, isPersisted: true),
      ),
      residueCounter: _residueCount,
    );
    _sessionUserService = SessionUserService(_database!.rawDatabase);
    _initialized = true;
  }

  /// Initialize SDK (call this first).
  ///
  /// [autoRestoreAndSync] (optional, default `false`):
  /// - tries to restore session (mobile_auth / OAuth / API key)
  /// - if successful, runs an initial metadata + data sync for mobile doctypes
  Future<void> initialize([bool autoRestoreAndSync = false]) async {
    if (_initialized) return;

    _database = await AppDatabase.getInstance(appName: databaseAppName);
    _authService = AuthService();
    _authService!.initialize(baseUrl, database: _database);

    // Use the same authenticated client instance everywhere so that
    // meta/sync/link-options calls always carry the Bearer token / API key.
    _client = _authService!.client;

    // Resolve session-bound offline mode BEFORE constructing services so
    // every service receives the correct mode through its constructor.
    final persistedMode = await SdkMetaDao(
      _database!.rawDatabase,
    ).readOfflineMode();
    _offlineMode = await _resolveBootMode(persistedMode);

    _metaService = MetaService(_client!, _database!);
    final rawDb = _database!.rawDatabase;
    final metaSvc = _metaService!;
    final metaFn = metaSvc.getMeta;
    final localWriter = LocalWriter(rawDb, metaFn);
    _repository = OfflineRepository(
      _database!,
      localWriter: localWriter,
      offlineMode: _offlineMode,
      client: _client!,
    );
    _permissionService = PermissionService(_client!, _database!);
    _translationService = TranslationService(_client!);
    _syncService = SyncService(
      _client!,
      _repository!,
      _database!,
      getMobileUuid: () => _authService!.getOrCreateMobileUuid(),
      offlineMode: _offlineMode,
    );
    // Build UnifiedResolver — single read path for all offline queries.
    // Probe connectivity once here; downstream callers (resolver,
    // _initialMetaAndDataSync) read `_cachedOnline` instead of probing
    // again, keeping launch to a single platform-channel round-trip.
    _cachedOnline = await _defaultIsOnline();
    final syncSvc = _syncService!;
    final resolver = UnifiedResolver(
      db: rawDb,
      metaDao: DoctypeMetaDao(rawDb),
      isOnline: () => _cachedOnline,
      backgroundFetch: (doctype, _) async {
        try {
          await syncSvc.pullSync(doctype: doctype);
        } catch (_) {}
      },
      metaResolver: metaFn,
      offlineMode: _offlineMode,
      client: _client!,
    );
    _linkOptionService = LinkOptionService(resolver, metaFn);

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
        getMobileUuid: () => _authService!.getOrCreateMobileUuid(),
        offlineMode: const OfflineMode(enabled: true, isPersisted: true),
      ),
      residueCounter: _residueCount,
    );

    _sessionUserService = SessionUserService(_database!.rawDatabase);
    // Best-effort: re-hydrate any persisted SessionUser from the previous
    // app run. Idempotent — no-op when sdk_meta.session_user_json is null.
    await _sessionUserService!.restoreFromDb();

    _initialized = true;

    if (autoRestoreAndSync) {
      final restored = await _authService!.restoreSession();
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
          unawaited(_offlineTransitionService!.runDrainAndWipe());
        }
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

  /// Runs the v1 → v2 offline-first data migration if it has not yet been
  /// applied (`sdk_meta.schema_version < 2`).
  ///
  /// Returns `true` if the migration ran, `false` if it was already applied.
  /// Throws [MigrationNeedsNetworkException] when the device is offline; the
  /// caller is expected to display [MigrationBlockedScreen] until connectivity
  /// returns and then retry.
  ///
  /// **WARNING — do not call until the new offline-first read/write engines
  /// (P3 + P4) are wired.** This migration renames the legacy `documents`
  /// table to `documents__archived_v1`. The current
  /// [OfflineRepository] writes to `documents` via the legacy `DocumentDao`,
  /// so any read/write through it will fail once the rename has happened.
  /// Until P3 rewires `OfflineRepository` to the per-doctype tables, leave
  /// this method uncalled. The SDK does NOT auto-invoke it from
  /// [initialize].
  ///
  /// [isOnline] and [metaFetcher] are injection seams used by tests. In
  /// production both default to real implementations (connectivity_plus and
  /// the wired [MetaService]).
  Future<bool> runV1ToV2MigrationIfNeeded({
    Future<bool> Function()? isOnline,
    Future<DocTypeMeta> Function(String doctype)? metaFetcher,
  }) async {
    if (!_initialized) await initialize();
    final raw = _database!.rawDatabase;
    final currentVersion = await _readSchemaVersion(raw);
    if (currentVersion >= 2) return false;

    final online = await (isOnline ?? _defaultIsOnline)();
    if (!online) {
      throw MigrationNeedsNetworkException();
    }

    final migration = V1ToV2Migration(
      db: raw,
      metaFetcher:
          metaFetcher ?? (doctype) async => _metaService!.getMeta(doctype),
    );
    return migration.run();
  }

  Future<bool> _defaultIsOnline() async {
    final result = await Connectivity().checkConnectivity();
    return result.contains(ConnectivityResult.mobile) ||
        result.contains(ConnectivityResult.wifi) ||
        result.contains(ConnectivityResult.ethernet);
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

  Future<int> _readSchemaVersion(dynamic db) async {
    final rows = await db.rawQuery(
      'SELECT schema_version FROM sdk_meta WHERE id=1 LIMIT 1',
    );
    if (rows.isEmpty) return 2;
    return (rows.first['schema_version'] as int?) ?? 0;
  }

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
    return response;
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

  /// Logout and clear all local DB data (default). Set clearDatabase: false to keep DB.
  Future<void> logout({bool clearDatabase = true}) async {
    if (!_initialized) {
      throw StateError(
        'Cannot logout: SDK not initialized. Call initialize() first.',
      );
    }
    await _authService!.logout(clearDatabase: clearDatabase);
  }

  /// Get Frappe API client (for direct API calls)
  ///
  /// Example:
  /// ```dart
  /// final client = sdk.api;
  /// await client.document.createDocument('Customer', {'name': 'Test'});
  /// ```
  FrappeClient get api {
    if (!_initialized) {
      throw Exception('SDK not initialized. Call initialize() first.');
    }
    return _client!;
  }

  /// Get Auth Service
  AuthService get auth {
    if (!_initialized) {
      throw Exception('SDK not initialized. Call initialize() first.');
    }
    return _authService!;
  }

  /// Get Meta Service
  MetaService get meta {
    if (!_initialized) {
      throw Exception('SDK not initialized. Call initialize() first.');
    }
    return _metaService!;
  }

  /// Get Permission Service (doctype read/write/create/delete from login or mobile_auth.permissions)
  PermissionService get permissions {
    if (!_initialized) {
      throw Exception('SDK not initialized. Call initialize() first.');
    }
    return _permissionService!;
  }

  /// Get Translation Service (Frappe translations via mobile_auth.get_translations).
  /// Use [TranslationService.loadTranslations] then [TranslationService.translate] or [TranslationService.call].
  TranslationService get translations {
    if (!_initialized) {
      throw Exception('SDK not initialized. Call initialize() first.');
    }
    return _translationService!;
  }

  /// Get Sync Service
  SyncService get sync {
    if (!_initialized) {
      throw Exception('SDK not initialized. Call initialize() first.');
    }
    return _syncService!;
  }

  /// Get the SessionUser service. Spec §6.6.
  ///
  /// The consumer wires login response → [SessionUser] via this service:
  /// `FrappeSDK.instance.sessionUserService.set(SessionUser.fromJson(loginResponse))`
  /// after a successful auth call. Logout flows call `.clear()` before
  /// running [AtomicWipe.wipe] to drop the persisted JSON.
  SessionUserService get sessionUserService {
    if (!_initialized) {
      throw Exception('SDK not initialized. Call initialize() first.');
    }
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
    if (!_initialized) {
      throw Exception('SDK not initialized. Call initialize() first.');
    }
    return _repository!;
  }

  /// Get the offline → online transition service.
  ///
  /// Subscribers listen on [OfflineTransitionService.stream] to react
  /// to drain progress, drain failures, and the wipe step. Consumer
  /// apps mount [OfflineTransitionScreen] above their router driven by
  /// this stream. Spec §7.
  OfflineTransitionService get offlineTransition {
    if (!_initialized) {
      throw Exception('SDK not initialized. Call initialize() first.');
    }
    return _offlineTransitionService!;
  }

  /// Get Link Option Service
  LinkOptionService get linkOptions {
    if (!_initialized) {
      throw Exception('SDK not initialized. Call initialize() first.');
    }
    return _linkOptionService!;
  }

  /// Get Database instance
  AppDatabase get database {
    if (!_initialized) {
      throw Exception('SDK not initialized. Call initialize() first.');
    }
    return _database!;
  }

  /// Check if authenticated
  bool get isAuthenticated => _authService?.isAuthenticated ?? false;

  /// Roles for the currently authenticated user (if provided by backend).
  List<String> get roles => _authService?.roles ?? const [];

  /// Returns the current authenticated user's info, or null.
  ({String email, String fullName})? get currentUser =>
      _authService?.currentUserInfo;

  /// Stable UUID for this device/install. Use when creating docs from mobile so server can set mobile_uuid.
  Future<String> getMobileUuid() async {
    if (!_initialized) await initialize();
    return await _authService!.getOrCreateMobileUuid();
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

  /// Persists the `offline_enabled` flag from a login response to
  /// `sdk_meta`. Treats a missing or non-`true` value as `false`.
  ///
  /// Non-fatal: write failures are logged and swallowed so a transient
  /// SQLite error doesn't fail the login itself. The persisted value
  /// takes effect on the next [initialize] call.
  Future<void> _persistOfflineFlagFromLogin(
    Map<String, dynamic> response,
  ) async {
    if (_database == null) return;
    final incoming = response['offline_enabled'] == true;
    try {
      await SdkMetaDao(_database!.rawDatabase).writeOfflineMode(
        enabled: incoming,
        setAtMs: DateTime.now().millisecondsSinceEpoch,
      );
    } catch (e, st) {
      // ignore: avoid_print
      print('FrappeSDK: failed to persist offline_enabled — $e\n$st');
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
  Future<void> _initialMetaAndDataSync() async {
    if (_metaService == null || _syncService == null) return;

    // Offline launch: every call below is pure-network and would block
    // on the HTTP timeout (~30s each, ~4 minutes total) before failing.
    // `_cachedOnline` was set during initialize() so reading it here is
    // race-free.
    if (!_cachedOnline) return;

    try {
      await _permissionService?.syncFromApi();
    } catch (_) {
      // ignore
    }

    try {
      await _translationService?.loadTranslations('en');
    } catch (_) {
      // ignore
    }

    try {
      await _metaService!.checkAndSyncDoctypes();
    } catch (_) {
      // ignore
    }

    try {
      await _metaService!.resyncMobileConfiguration();
    } catch (_) {
      // ignore
    }

    // Online mode stops here — closure pull is offline-only.
    if (!_offlineMode.enabled) return;

    try {
      // Pull data for entry-point (mobile form) doctypes AND every doctype
      // they reach via Link / Table / Table MultiSelect — i.e. the
      // dependency closure. Spec §3.2 + §5.1.
      //
      // Without this, Link pickers on offline forms have nothing to show
      // (e.g. an Order form needs Customer + Item populated locally before
      // the user can fill its Link fields). Child-table doctypes are
      // excluded — they ride along inside their parent's records and
      // don't need their own pull.
      final entryPoints = await _metaService!.getMobileFormDoctypeNames();
      final closure = await _metaService!.closure(entryPoints);
      final toPull = closure.doctypes
          .where((d) => !closure.childDoctypes.contains(d))
          .toList();
      for (final doctype in toPull) {
        // Skip doctypes the user cannot read — avoids wasteful 403 requests.
        // canRead() defaults to true when no permission record exists.
        if (_permissionService != null &&
            !await _permissionService!.canRead(doctype)) {
          continue;
        }
        try {
          await _syncService!.pullSync(doctype: doctype);
        } catch (_) {
          continue;
        }
      }
    } catch (_) {
      // ignore data sync errors
    }
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
  Future<void> dispose() async {
    await _sessionUserService?.dispose();
    _sessionUserService = null;
    await _offlineTransitionService?.dispose();
    _offlineTransitionService = null;
    _initialized = false;
  }
}
