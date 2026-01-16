import 'package:erpnext_sdk_flutter/erpnext_sdk_flutter.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Service for handling Frappe authentication
class AuthService {
  static const String _keyBaseUrl = 'frappe_base_url';
  static const String _keyApiKey = 'frappe_api_key';
  static const String _keyApiSecret = 'frappe_api_secret';
  static const String _keyToken = 'frappe_token';

  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  ERPNextClient? _client;
  bool _isAuthenticated = false;

  /// Initialize with base URL
  void initialize(String baseUrl) {
    _client = ERPNextClient(baseUrl);
    _storage.write(key: _keyBaseUrl, value: baseUrl);
  }

  /// Get base URL
  Future<String?> getBaseUrl() async {
    return await _storage.read(key: _keyBaseUrl);
  }

  /// Get ERPNext client instance
  ERPNextClient? get client => _client;

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
      
      // Note: ERPNext SDK handles token storage internally
      // We just mark as authenticated
      
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

  /// Restore session from stored credentials
  Future<bool> restoreSession() async {
    final baseUrl = await getBaseUrl();
    if (baseUrl == null) {
      return false;
    }

    // Initialize if not already done
    if (_client == null) {
      initialize(baseUrl);
    }

    // Try API key first
    final apiKey = await _storage.read(key: _keyApiKey);
    final apiSecret = await _storage.read(key: _keyApiSecret);
    if (apiKey != null && apiSecret != null) {
      try {
        _client!.auth.setApiKey(apiKey, apiSecret);
        _isAuthenticated = true;
        return true;
      } catch (e) {
        print('Failed to restore API key session: $e');
        return false;
      }
    }

    // Check if client has valid session (ERPNext SDK manages tokens internally)
    // The SDK might have a valid session from previous login
    // We can't directly check, so we'll assume false and require re-login
    // This is safer than assuming we're authenticated
    
    return false;
  }

  /// Logout
  Future<void> logout() async {
    try {
      await _client?.auth.logout();
    } catch (e) {
      // Ignore logout errors
    }
    
    _isAuthenticated = false;
    // Note: ERPNext SDK clears its own tokens on logout
    await _storage.delete(key: _keyApiKey);
    await _storage.delete(key: _keyApiSecret);
  }

  /// Clear all stored credentials
  Future<void> clearCredentials() async {
    await _storage.deleteAll();
    _isAuthenticated = false;
    _client = null;
  }
}
