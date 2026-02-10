// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// For license information, please see license.txt

import '../api/client.dart';
import '../database/app_database.dart';
import '../services/auth_service.dart';
import '../services/meta_service.dart';
import '../services/sync_service.dart';
import '../services/offline_repository.dart';
import '../services/link_option_service.dart';

/// Main SDK initialization class for easy setup
class FrappeSDK {
  final String baseUrl;

  FrappeClient? _client;
  AppDatabase? _database;
  AuthService? _authService;
  MetaService? _metaService;
  SyncService? _syncService;
  OfflineRepository? _repository;
  LinkOptionService? _linkOptionService;

  bool _initialized = false;

  FrappeSDK({required this.baseUrl});

  /// Initialize SDK (call this first).
  ///
  /// [autoRestoreAndSync] (optional, default `false`):
  /// - tries to restore session (mobile_auth / OAuth / API key)
  /// - if successful, runs an initial metadata + data sync for mobile doctypes
  Future<void> initialize([bool autoRestoreAndSync = false]) async {
    if (_initialized) return;

    _database = await AppDatabase.getInstance();
    _authService = AuthService();
    _authService!.initialize(baseUrl, database: _database);

    // Use the same authenticated client instance everywhere so that
    // meta/sync/link-options calls always carry the Bearer token / API key.
    _client = _authService!.client;

    _repository = OfflineRepository(_database!);
    _metaService = MetaService(_client!, _database!);
    _syncService = SyncService(
      _client!,
      _repository!,
      _database!,
      getMobileUuid: () => _authService!.getOrCreateMobileUuid(),
    );
    _linkOptionService = LinkOptionService(_client!);

    _initialized = true;

    if (autoRestoreAndSync) {
      final restored = await _authService!.restoreSession();
      if (restored) {
        await _initialMetaAndDataSync();
      }
    }
  }

  /// Login with username and password (stateless, returns user info)
  Future<Map<String, dynamic>> login(String username, String password) async {
    if (!_initialized) await initialize();
    return await _authService!.login(username, password);
  }

  /// Login with API key
  Future<bool> loginWithApiKey(String apiKey, String apiSecret) async {
    if (!_initialized) await initialize();
    return await _authService!.loginWithApiKey(apiKey, apiSecret);
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
    return await _authService!.loginWithOAuth(
      code: code,
      codeVerifier: codeVerifier,
      clientId: clientId,
      redirectUri: redirectUri,
    );
  }

  /// Logout and clear all local DB data (default). Set clearDatabase: false to keep DB.
  Future<void> logout({bool clearDatabase = true}) async {
    if (!_initialized) return;
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

  /// Get Sync Service
  SyncService get sync {
    if (!_initialized) {
      throw Exception('SDK not initialized. Call initialize() first.');
    }
    return _syncService!;
  }

  /// Get Repository (for offline operations)
  OfflineRepository get repository {
    if (!_initialized) {
      throw Exception('SDK not initialized. Call initialize() first.');
    }
    return _repository!;
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

  /// Internal: initial metadata + data sync for mobile doctypes.
  ///
  /// 1) Sync doctypes from login mobile_form_names (checkAndSyncDoctypes)
  /// 2) Resync configuration from server (mobile_auth.configuration)
  /// 3) Pull records for all mobile doctypes into the offline DB
  Future<void> _initialMetaAndDataSync() async {
    if (_metaService == null || _syncService == null) return;

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

    try {
      final doctypes = await _metaService!.getMobileFormDoctypeNames();
      for (final doctype in doctypes) {
        try {
          await _syncService!.pullSync(doctype: doctype);
        } catch (_) {
          // continue with other doctypes
          continue;
        }
      }
    } catch (_) {
      // ignore data sync errors
    }
  }
}
