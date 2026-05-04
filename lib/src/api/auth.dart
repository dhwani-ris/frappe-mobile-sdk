// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// For license information, please see license.txt

import 'rest_helper.dart';

abstract class SessionStorage {
  Future<void> saveSession(String sid);
  Future<String?> getSession();
  Future<void> clearSession();
}

class InMemorySessionStorage implements SessionStorage {
  String? _sid;
  @override
  Future<void> saveSession(String sid) async => _sid = sid;
  @override
  Future<String?> getSession() async => _sid;
  @override
  Future<void> clearSession() async => _sid = null;
}

class AuthService {
  final RestHelper _restHelper;
  final SessionStorage _sessionStorage;

  AuthService(this._restHelper, {SessionStorage? sessionStorage})
    : _sessionStorage = sessionStorage ?? InMemorySessionStorage();

  Future<void> initialize() async {
    final sid = await _sessionStorage.getSession();
    if (sid != null) {
      _restHelper.setSessionCookie(sid);
    }
  }

  void setApiKey(String apiKey, String apiSecret) {
    _restHelper.setApiKey(apiKey, apiSecret);
  }

  Future<void> logout() async {
    try {
      await _restHelper.post('/api/method/mobile_auth.logout');
    } catch (_) {
      // Ignore logout errors
    } finally {
      _restHelper.clearSession();
      await _sessionStorage.clearSession();
    }
  }
}
