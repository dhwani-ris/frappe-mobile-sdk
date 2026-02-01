import '../api/client.dart';
import '../api/oauth2_helper.dart';
import '../database/app_database.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Service for handling Frappe authentication (credentials, API key, OAuth 2.0)
class AuthService {
  static const String _keyBaseUrl = 'frappe_base_url';
  static const String _keyApiKey = 'frappe_api_key';
  static const String _keyApiSecret = 'frappe_api_secret';
  static const String _keyOAuthAccessToken = 'frappe_oauth_access_token';
  static const String _keyOAuthRefreshToken = 'frappe_oauth_refresh_token';
  static const String _keyOAuthExpiresAt = 'frappe_oauth_expires_at';
  static const String _keyOAuthClientId = 'frappe_oauth_client_id';

  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  FrappeClient? _client;
  bool _isAuthenticated = false;

  /// Initialize with base URL
  void initialize(String baseUrl) {
    _client = FrappeClient(baseUrl);
    _storage.write(key: _keyBaseUrl, value: baseUrl);
  }

  /// Get base URL
  Future<String?> getBaseUrl() async {
    return await _storage.read(key: _keyBaseUrl);
  }

  /// Get Frappe client instance
  FrappeClient? get client => _client;

  /// Check if authenticated
  bool get isAuthenticated => _isAuthenticated && _client != null;

  /// Login with username and password
  Future<bool> login(String username, String password) async {
    if (_client == null) {
      throw Exception('AuthService not initialized. Call initialize() first.');
    }

    try {
      await _client!.auth.loginWithCredentials(username, password);
      _isAuthenticated = true;
      return true;
    } catch (e) {
      _isAuthenticated = false;
      throw Exception('Login failed: $e');
    }
  }

  /// Login with API key and secret
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

  /// Restore session from stored credentials (OAuth first, then API key)
  Future<bool> restoreSession() async {
    final baseUrl = await getBaseUrl();
    if (baseUrl == null) return false;

    if (_client == null) {
      initialize(baseUrl);
    }

    final accessToken = await _storage.read(key: _keyOAuthAccessToken);
    final refreshToken = await _storage.read(key: _keyOAuthRefreshToken);
    final expiresAtStr = await _storage.read(key: _keyOAuthExpiresAt);

    if (accessToken != null && accessToken.isNotEmpty) {
      final expiresAt = expiresAtStr != null ? int.tryParse(expiresAtStr) : null;
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      if (expiresAt == null || expiresAt > now + 60) {
        _client!.rest.setBearerToken(accessToken);
        _isAuthenticated = true;
        return true;
      }
      final oauthClientId = await _storage.read(key: _keyOAuthClientId);
      if (refreshToken != null &&
          refreshToken.isNotEmpty &&
          oauthClientId != null &&
          oauthClientId.isNotEmpty) {
        try {
          final refreshed = await OAuth2Helper.refreshToken(
            baseUrl: baseUrl,
            clientId: oauthClientId,
            refreshToken: refreshToken,
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

  Future<void> _clearOAuthTokens() async {
    await _storage.delete(key: _keyOAuthAccessToken);
    await _storage.delete(key: _keyOAuthRefreshToken);
    await _storage.delete(key: _keyOAuthExpiresAt);
    await _storage.delete(key: _keyOAuthClientId);
  }

  /// Login via Frappe OAuth 2.0 (authorization code + PKCE).
  /// After user authorizes in browser, capture redirect with ?code=... and call this.
  Future<bool> loginWithOAuth({
    required String code,
    required String codeVerifier,
    required String clientId,
    required String redirectUri,
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
      );
      await _storeOAuthTokens(
        tokens.accessToken,
        tokens.refreshToken ?? '',
        tokens.expiresIn,
      );
      await _storage.write(key: _keyOAuthClientId, value: clientId);
      _client!.rest.setBearerToken(tokens.accessToken);
      _isAuthenticated = true;
      return true;
    } catch (e) {
      _isAuthenticated = false;
      throw Exception('OAuth login failed: $e');
    }
  }

  /// Build OAuth authorize URL and generate PKCE. Return URL + codeVerifier for later exchange.
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
    return {
      'authorize_url': url,
      'code_verifier': pkce.codeVerifier,
    };
  }

  /// Logout and optionally clear all local database data.
  /// When [clearDatabase] is true (default), all tables are wiped.
  Future<void> logout({bool clearDatabase = true}) async {
    try {
      await _client?.auth.logout();
    } catch (_) {}
    _client?.rest.setBearerToken(null);
    _isAuthenticated = false;
    await _storage.delete(key: _keyApiKey);
    await _storage.delete(key: _keyApiSecret);
    await _clearOAuthTokens();
    if (clearDatabase) {
      await AppDatabase.clearAllData();
    }
  }

  /// Clear all stored credentials (does not clear DB)
  Future<void> clearCredentials() async {
    await _storage.deleteAll();
    _isAuthenticated = false;
    _client = null;
  }
}
