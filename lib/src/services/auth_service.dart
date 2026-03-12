import 'dart:developer' as dev;

import '../api/client.dart';
import '../api/oauth2_helper.dart';
import '../database/app_database.dart';
import '../database/entities/auth_token_entity.dart';
import '../database/entities/doctype_meta_entity.dart';
import '../models/mobile_form_name.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

/// Handles Frappe authentication via credentials, API key, or OAuth 2.0.
///
/// Tokens are stored in secure storage. OAuth tokens are automatically
/// refreshed on 401 when [onTokenExpired] is configured.
class AuthService {
  static const String _keyBaseUrl = 'frappe_base_url';
  static const String _keyApiKey = 'frappe_api_key';
  static const String _keyApiSecret = 'frappe_api_secret';
  static const String _keyOAuthAccessToken = 'frappe_oauth_access_token';
  static const String _keyOAuthRefreshToken = 'frappe_oauth_refresh_token';
  static const String _keyOAuthExpiresAt = 'frappe_oauth_expires_at';
  static const String _keyOAuthClientId = 'frappe_oauth_client_id';
  static const String _keyOAuthClientSecret = 'frappe_oauth_client_secret';
  static const String _keyMobileUuid = 'frappe_mobile_uuid';

  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  static const Uuid _uuid = Uuid();
  FrappeClient? _client;
  bool _isAuthenticated = false;
  AppDatabase? _database;
  List<String> _roles = [];
  String? _language;

  /// Initializes the client with the given [baseUrl].
  ///
  /// Optionally provide [database] for stateless login token storage.
  void initialize(String baseUrl, {AppDatabase? database}) {
    _client = FrappeClient(baseUrl, onTokenExpired: _tryRefreshMobileAuthToken);
    _database = database;
    _storage.write(key: _keyBaseUrl, value: baseUrl);
  }

  /// Returns the stored base URL, or null if not set.
  Future<String?> getBaseUrl() async {
    return _storage.read(key: _keyBaseUrl);
  }

  /// Returns a stable UUID for this device/install. Creates and stores one if missing.
  /// Use when creating documents from mobile so server can store mobile_uuid.
  Future<String> getOrCreateMobileUuid() async {
    var value = await _storage.read(key: _keyMobileUuid);
    if (value == null || value.isEmpty) {
      value = _uuid.v4();
      await _storage.write(key: _keyMobileUuid, value: value);
    }
    return value;
  }

  /// The Frappe API client. Null until [initialize] is called.
  FrappeClient? get client => _client;

  /// True if authenticated and client is initialized.
  bool get isAuthenticated => _isAuthenticated && _client != null;

  /// Roles for the currently authenticated user (if provided by backend).
  List<String> get roles => List.unmodifiable(_roles);

  /// User language from login/OTP/me response (e.g. "en"). Null until set.
  String? get language => _language;

  /// Authenticates with username and password using mobile_auth.login (stateless).
  ///
  /// This is the default login method. Stores access_token and refresh_token in database.
  /// Returns user info including mobile_form_names.
  /// Throws if not initialized, database not set, or credentials are invalid.
  Future<Map<String, dynamic>> login(String username, String password) async {
    if (_client == null) {
      throw Exception('AuthService not initialized. Call initialize() first.');
    }
    if (_database == null) {
      throw Exception(
        'Database not set. Call initialize(baseUrl, database: db) first.',
      );
    }

    try {
      final result = await _client!.rest.call(
        'mobile_auth.login',
        args: {'username': username, 'password': password},
      );

      final response = result is Map<String, dynamic>
          ? (result['message'] is Map ? result['message'] : result)
          : <String, dynamic>{};

      final accessToken = response['access_token'] as String?;
      final refreshToken = response['refresh_token'] as String?;
      final user = response['user'] as String?;
      final fullName = response['full_name'] as String?;
      final mobileFormNamesJson =
          response['mobile_form_names'] as List<dynamic>?;

      // Roles: top-level response['roles'] (new) or response['permissions']['roles'] (legacy)
      final rolesJson = response['roles'] as List<dynamic>?;
      if (rolesJson != null && rolesJson.isNotEmpty) {
        _roles = rolesJson
            .map((r) => r.toString())
            .where((r) => r.isNotEmpty)
            .toList();
      } else {
        final permissionsMap = response['permissions'] as Map<String, dynamic>?;
        final legacyRoles = permissionsMap?['roles'] as List<dynamic>?;
        _roles =
            legacyRoles
                ?.map((r) => r.toString())
                .where((r) => r.isNotEmpty)
                .toList() ??
            <String>[];
      }

      _language = response['language'] as String?;

      if (accessToken == null || accessToken.isEmpty) {
        throw Exception('Login response missing access_token');
      }
      if (refreshToken == null || refreshToken.isEmpty) {
        throw Exception('Login response missing refresh_token');
      }
      if (user == null || user.isEmpty) {
        throw Exception('Login response missing user');
      }
      dev.log('access_token: $accessToken', name: 'Auth');

      await _processLoginResponse(
        response,
        accessToken,
        refreshToken,
        user,
        fullName,
        mobileFormNamesJson,
      );
      return response;
    } catch (e) {
      _isAuthenticated = false;
      if (e is Exception) rethrow;
      throw Exception('Login failed: $e');
    }
  }

  /// Sends OTP to mobile number for login. Returns response containing tmp_id.
  /// Call [verifyLoginOtp] with tmp_id and user-entered OTP to complete login.
  Future<Map<String, dynamic>> sendLoginOtp(String mobileNo) async {
    if (_client == null) {
      throw Exception('AuthService not initialized. Call initialize() first.');
    }
    final result = await _client!.rest.call(
      'mobile_auth.send_login_otp',
      args: {'mobile_no': mobileNo},
    );
    final response = result is Map<String, dynamic>
        ? (result['message'] is Map ? result['message'] : result)
        : <String, dynamic>{};
    return response;
  }

  /// Verifies OTP and completes login. Returns same shape as [login].
  /// [tmpId] from [sendLoginOtp] response; [otp] is user-entered code.
  Future<Map<String, dynamic>> verifyLoginOtp(String tmpId, String otp) async {
    if (_client == null) {
      throw Exception('AuthService not initialized. Call initialize() first.');
    }
    if (_database == null) {
      throw Exception(
        'Database not set. Call initialize(baseUrl, database: db) first.',
      );
    }
    try {
      final result = await _client!.rest.call(
        'mobile_auth.verify_login_otp',
        args: {'tmp_id': tmpId, 'otp': otp},
      );
      final response = result is Map<String, dynamic>
          ? (result['message'] is Map ? result['message'] : result)
          : <String, dynamic>{};

      final accessToken = response['access_token'] as String?;
      final refreshToken = response['refresh_token'] as String?;
      final user = response['user'] as String?;
      final fullName = response['full_name'] as String?;
      final mobileFormNamesJson =
          response['mobile_form_names'] as List<dynamic>?;

      if (accessToken == null || accessToken.isEmpty) {
        throw Exception('Verify OTP response missing access_token');
      }
      if (refreshToken == null || refreshToken.isEmpty) {
        throw Exception('Verify OTP response missing refresh_token');
      }
      if (user == null || user.isEmpty) {
        throw Exception('Verify OTP response missing user');
      }
      dev.log('access_token: $accessToken', name: 'Auth');

      // Roles and language (same as login)
      final rolesJson = response['roles'] as List<dynamic>?;
      if (rolesJson != null && rolesJson.isNotEmpty) {
        _roles = rolesJson
            .map((r) => r.toString())
            .where((r) => r.isNotEmpty)
            .toList();
      } else {
        final permissionsMap = response['permissions'] as Map<String, dynamic>?;
        final legacyRoles = permissionsMap?['roles'] as List<dynamic>?;
        _roles =
            legacyRoles
                ?.map((r) => r.toString())
                .where((r) => r.isNotEmpty)
                .toList() ??
            <String>[];
      }
      _language = response['language'] as String?;

      await _processLoginResponse(
        response,
        accessToken,
        refreshToken,
        user,
        fullName,
        mobileFormNamesJson,
      );
      return response;
    } catch (e) {
      _isAuthenticated = false;
      if (e is Exception) rethrow;
      throw Exception('Verify OTP failed: $e');
    }
  }

  /// Fetches current user info (roles, permissions, language, mobile_form_names).
  /// Call after OAuth or API key login to get the same shape as login response.
  /// Backend must expose e.g. mobile_auth.me returning that payload.
  Future<Map<String, dynamic>?> fetchUserInfo() async {
    if (_client == null || !_isAuthenticated) return null;
    try {
      final result = await _client!.rest.get('/api/v2/method/mobile_auth.me');
      if (result is! Map<String, dynamic>) return null;
      final data = result['data'] as Map<String, dynamic>? ?? result;
      final message = data['message'] as Map<String, dynamic>? ?? data;

      final rolesJson = message['roles'] as List<dynamic>?;
      if (rolesJson != null && rolesJson.isNotEmpty) {
        _roles = rolesJson
            .map((r) => r.toString())
            .where((r) => r.isNotEmpty)
            .toList();
      } else {
        final permissionsMap = message['permissions'] as Map<String, dynamic>?;
        final legacyRoles = permissionsMap?['roles'] as List<dynamic>?;
        _roles =
            legacyRoles
                ?.map((r) => r.toString())
                .where((r) => r.isNotEmpty)
                .toList() ??
            <String>[];
      }
      _language = message['language'] as String?;
      return message;
    } catch (_) {
      return null;
    }
  }

  Future<void> _processLoginResponse(
    Map<String, dynamic> response,
    String accessToken,
    String refreshToken,
    String user,
    String? fullName,
    List<dynamic>? mobileFormNamesJson,
  ) async {
    final tokenEntity = AuthTokenEntity(
      accessToken: accessToken,
      refreshToken: refreshToken,
      user: user,
      fullName: fullName,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );

    final existing = await _database!.authTokenDao.getCurrentToken();
    if (existing != null) {
      await _database!.authTokenDao.updateToken(tokenEntity);
    } else {
      await _database!.authTokenDao.insertToken(tokenEntity);
    }

    if (mobileFormNamesJson != null && mobileFormNamesJson.isNotEmpty) {
      final mobileFormNames = mobileFormNamesJson
          .map((json) => MobileFormName.fromJson(json as Map<String, dynamic>))
          .toList();

      final allMetas = await _database!.doctypeMetaDao.findAll();
      for (final meta in allMetas) {
        if (meta.isMobileForm) {
          final updatedMeta = DoctypeMetaEntity(
            doctype: meta.doctype,
            modified: meta.modified,
            serverModifiedAt: meta.serverModifiedAt,
            isMobileForm: false,
            metaJson: meta.metaJson,
          );
          await _database!.doctypeMetaDao.updateDoctypeMeta(updatedMeta);
        }
      }

      for (final mfn in mobileFormNames) {
        final doctype = mfn.mobileDoctype;
        final existingMeta = await _database!.doctypeMetaDao.findByDoctype(
          doctype,
        );

        if (existingMeta != null) {
          final updatedMeta = DoctypeMetaEntity(
            doctype: doctype,
            modified: existingMeta.modified,
            serverModifiedAt: mfn.doctypeMetaModifiedAt,
            isMobileForm: true,
            metaJson: existingMeta.metaJson,
          );
          await _database!.doctypeMetaDao.updateDoctypeMeta(updatedMeta);
        } else {
          final newMeta = DoctypeMetaEntity(
            doctype: doctype,
            modified: null,
            serverModifiedAt: mfn.doctypeMetaModifiedAt,
            isMobileForm: true,
            metaJson: '{}',
          );
          await _database!.doctypeMetaDao.insertDoctypeMeta(newMeta);
        }
      }
    }

    _client!.rest.setBearerToken(accessToken);
    _isAuthenticated = true;
  }

  /// Authenticates with API key and secret.
  ///
  /// Throws if not initialized or credentials are invalid.
  Future<bool> loginWithApiKey(String apiKey, String apiSecret) async {
    if (_client == null) {
      throw Exception('AuthService not initialized. Call initialize() first.');
    }
    try {
      _client!.auth.setApiKey(apiKey, apiSecret);
      await _storage.write(key: _keyApiKey, value: apiKey);
      await _storage.write(key: _keyApiSecret, value: apiSecret);
      _isAuthenticated = true;
      return true;
    } catch (e) {
      _isAuthenticated = false;
      throw Exception('API key login failed: $e');
    }
  }

  /// Restores session from stored credentials.
  ///
  /// Tries mobile auth tokens (from DB) first, then OAuth tokens, then API key.
  /// Returns true if a valid session was restored.
  Future<bool> restoreSession() async {
    final baseUrl = await getBaseUrl();
    if (baseUrl == null) return false;

    if (_client == null) {
      initialize(baseUrl, database: _database);
    }

    // Try mobile auth tokens from database first
    if (_database != null) {
      try {
        final token = await _database!.authTokenDao.getCurrentToken();
        if (token != null && token.accessToken.isNotEmpty) {
          _client!.rest.setBearerToken(token.accessToken);
          _isAuthenticated = true;
          return true;
        }
      } catch (_) {
        // Continue to other auth methods
      }
    }

    final accessToken = await _storage.read(key: _keyOAuthAccessToken);
    final refreshToken = await _storage.read(key: _keyOAuthRefreshToken);
    final expiresAtStr = await _storage.read(key: _keyOAuthExpiresAt);

    if (accessToken != null && accessToken.isNotEmpty) {
      final expiresAt = expiresAtStr != null
          ? int.tryParse(expiresAtStr)
          : null;
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      if (expiresAt == null || expiresAt > now + 60) {
        _client!.rest.setBearerToken(accessToken);
        _isAuthenticated = true;
        return true;
      }
      final oauthClientId = await _storage.read(key: _keyOAuthClientId);
      final oauthClientSecret = await _storage.read(key: _keyOAuthClientSecret);
      if (refreshToken != null &&
          refreshToken.isNotEmpty &&
          oauthClientId != null &&
          oauthClientId.isNotEmpty) {
        try {
          final refreshed = await OAuth2Helper.refreshToken(
            baseUrl: baseUrl,
            clientId: oauthClientId,
            refreshToken: refreshToken,
            clientSecret: oauthClientSecret,
          );
          await _storeOAuthTokens(
            refreshed.accessToken,
            refreshed.refreshToken ?? refreshToken,
            refreshed.expiresIn,
          );
          _client!.rest.setBearerToken(refreshed.accessToken);
          _isAuthenticated = true;
          return true;
        } catch (_) {
          await _clearOAuthTokens();
        }
      }
    }

    final apiKey = await _storage.read(key: _keyApiKey);
    final apiSecret = await _storage.read(key: _keyApiSecret);
    if (apiKey != null && apiSecret != null) {
      try {
        _client!.auth.setApiKey(apiKey, apiSecret);
        _isAuthenticated = true;
        return true;
      } catch (_) {
        return false;
      }
    }

    return false;
  }

  /// Exchanges OAuth authorization code for tokens and authenticates.
  ///
  /// [code] and [codeVerifier] come from the OAuth redirect.
  /// [clientSecret] is required for confidential OAuth clients.
  Future<bool> loginWithOAuth({
    required String code,
    required String codeVerifier,
    required String clientId,
    required String redirectUri,
    String? clientSecret,
  }) async {
    if (_client == null) {
      throw Exception('AuthService not initialized. Call initialize() first.');
    }
    final baseUrl = await getBaseUrl();
    if (baseUrl == null) {
      throw Exception('Base URL not set. Call initialize(baseUrl) first.');
    }
    try {
      final tokens = await OAuth2Helper.exchangeCodeForToken(
        baseUrl: baseUrl,
        clientId: clientId,
        redirectUri: redirectUri,
        code: code,
        codeVerifier: codeVerifier,
        clientSecret: clientSecret,
      );
      dev.log(
        'loginWithOAuth success: access_token length=${tokens.accessToken.length}, refresh_token=${tokens.refreshToken != null ? "set" : "null"}, expires_in=${tokens.expiresIn}',
        name: 'Auth',
      );
      final accessToken = tokens.accessToken.trim();
      if (accessToken.isEmpty) {
        throw Exception('OAuth returned empty access token');
      }
      await _storeOAuthTokens(
        accessToken,
        (tokens.refreshToken ?? '').trim(),
        tokens.expiresIn,
      );
      await _storage.write(key: _keyOAuthClientId, value: clientId);
      if (clientSecret != null && clientSecret.isNotEmpty) {
        await _storage.write(key: _keyOAuthClientSecret, value: clientSecret);
      }
      _client!.rest.setBearerToken(accessToken);
      _isAuthenticated = true;
      return true;
    } catch (e) {
      _isAuthenticated = false;
      throw Exception('OAuth login failed: $e');
    }
  }

  /// Builds OAuth authorize URL and PKCE pair for the login flow.
  ///
  /// Returns a map with `authorize_url` and `code_verifier`.
  static Future<Map<String, String>> prepareOAuthLogin({
    required String baseUrl,
    required String clientId,
    required String redirectUri,
    String scope = 'openid all',
    String? state,
  }) async {
    final pkce = OAuth2Helper.generatePkce();
    final url = OAuth2Helper.getAuthorizeUrl(
      baseUrl: baseUrl,
      clientId: clientId,
      redirectUri: redirectUri,
      scope: scope,
      state: state ?? DateTime.now().millisecondsSinceEpoch.toString(),
      codeChallenge: pkce.codeChallenge,
    );
    return {'authorize_url': url, 'code_verifier': pkce.codeVerifier};
  }

  /// Logs out and clears stored credentials.
  ///
  /// If [clearDatabase] is true (default), wipes all local tables.
  Future<void> logout({bool clearDatabase = true}) async {
    try {
      await _client?.auth.logout();
    } catch (_) {}
    _client?.rest.setBearerToken(null);
    _isAuthenticated = false;
    _roles = [];
    await _storage.delete(key: _keyApiKey);
    await _storage.delete(key: _keyApiSecret);
    await _clearOAuthTokens();
    if (_database != null) {
      await _database!.authTokenDao.deleteAll();
    }
    if (clearDatabase) {
      await AppDatabase.clearAllData();
    }
  }

  /// Clears all stored credentials without touching the database.
  Future<void> clearCredentials() async {
    await _storage.deleteAll();
    _isAuthenticated = false;
    _client = null;
  }

  Future<void> _storeOAuthTokens(
    String accessToken,
    String refreshToken,
    int? expiresIn,
  ) async {
    await _storage.write(key: _keyOAuthAccessToken, value: accessToken);
    await _storage.write(key: _keyOAuthRefreshToken, value: refreshToken);
    if (expiresIn != null) {
      final expiresAt =
          (DateTime.now().millisecondsSinceEpoch ~/ 1000) + expiresIn;
      await _storage.write(
        key: _keyOAuthExpiresAt,
        value: expiresAt.toString(),
      );
    }
  }

  Future<bool> _tryRefreshMobileAuthToken() async {
    // Try mobile auth refresh first
    if (_database != null) {
      try {
        final token = await _database!.authTokenDao.getCurrentToken();
        if (token != null && token.refreshToken.isNotEmpty) {
          final baseUrl = await getBaseUrl();
          if (baseUrl != null) {
            // Call mobile_auth.refresh_token endpoint
            try {
              final result = await _client!.rest.call(
                'mobile_auth.refresh_token',
                args: {'refresh_token': token.refreshToken},
              );
              final response = result is Map<String, dynamic>
                  ? (result['message'] is Map ? result['message'] : result)
                  : <String, dynamic>{};
              final newAccessToken = response['access_token'] as String?;
              final newRefreshToken =
                  response['refresh_token'] as String? ?? token.refreshToken;

              if (newAccessToken != null && newAccessToken.isNotEmpty) {
                final updatedToken = AuthTokenEntity(
                  accessToken: newAccessToken,
                  refreshToken: newRefreshToken,
                  user: token.user,
                  fullName: token.fullName,
                  createdAt: token.createdAt,
                );
                await _database!.authTokenDao.updateToken(updatedToken);
                _client?.rest.setBearerToken(newAccessToken);
                return true;
              }
            } catch (_) {
              // Refresh failed, clear tokens
              await _database!.authTokenDao.deleteAll();
            }
          }
        }
      } catch (_) {
        // Continue to OAuth refresh
      }
    }

    // Fallback to OAuth refresh
    return await _tryRefreshOAuthToken();
  }

  Future<bool> _tryRefreshOAuthToken() async {
    final baseUrl = await getBaseUrl();
    final refreshToken = await _storage.read(key: _keyOAuthRefreshToken);
    final oauthClientId = await _storage.read(key: _keyOAuthClientId);
    final oauthClientSecret = await _storage.read(key: _keyOAuthClientSecret);
    if (baseUrl == null ||
        refreshToken == null ||
        refreshToken.isEmpty ||
        oauthClientId == null ||
        oauthClientId.isEmpty) {
      return false;
    }
    try {
      final refreshed = await OAuth2Helper.refreshToken(
        baseUrl: baseUrl,
        clientId: oauthClientId,
        refreshToken: refreshToken,
        clientSecret: oauthClientSecret,
      );
      await _storeOAuthTokens(
        refreshed.accessToken,
        refreshed.refreshToken ?? refreshToken,
        refreshed.expiresIn,
      );
      _client?.rest.setBearerToken(refreshed.accessToken);
      return true;
    } catch (_) {
      await _clearOAuthTokens();
      return false;
    }
  }

  Future<void> _clearOAuthTokens() async {
    await _storage.delete(key: _keyOAuthAccessToken);
    await _storage.delete(key: _keyOAuthRefreshToken);
    await _storage.delete(key: _keyOAuthExpiresAt);
    await _storage.delete(key: _keyOAuthClientId);
    await _storage.delete(key: _keyOAuthClientSecret);
  }
}
