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
  final List<String> doctypes;
  
  FrappeClient? _client;
  AppDatabase? _database;
  AuthService? _authService;
  MetaService? _metaService;
  SyncService? _syncService;
  OfflineRepository? _repository;
  LinkOptionService? _linkOptionService;
  
  bool _initialized = false;

  FrappeSDK({
    required this.baseUrl,
    required this.doctypes,
  });

  /// Initialize SDK (call this first)
  Future<void> initialize() async {
    if (_initialized) return;
    
    _database = await AppDatabase.getInstance();
    _client = FrappeClient(baseUrl);
    _authService = AuthService();
    _authService!.initialize(baseUrl);
    
    _repository = OfflineRepository(_database!);
    _metaService = MetaService(_client!, _database!);
    _syncService = SyncService(_client!, _repository!, _database!);
    _linkOptionService = LinkOptionService(_client!, _database!);
    
    _initialized = true;
  }

  /// Login with username and password
  Future<bool> login(String username, String password) async {
    if (!_initialized) await initialize();
    return await _authService!.login(username, password);
  }

  /// Login with API key
  Future<bool> loginWithApiKey(String apiKey, String apiSecret) async {
    if (!_initialized) await initialize();
    return await _authService!.loginWithApiKey(apiKey, apiSecret);
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

  /// Load metadata for all configured doctypes
  Future<void> loadMetadata() async {
    if (!_initialized) await initialize();
    await _metaService!.getMetas(doctypes);
  }

  /// Sync all configured doctypes
  Future<void> syncAll() async {
    if (!_initialized) await initialize();
    for (final doctype in doctypes) {
      await _syncService!.syncDoctype(doctype);
    }
  }
}
