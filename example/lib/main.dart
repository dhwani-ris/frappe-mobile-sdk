// ignore_for_file: use_build_context_synchronously
import 'package:flutter/material.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';

import 'config/app_config.dart' as config;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Frappe Mobile SDK Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: FrappeAppGuard(
        baseUrl: config.AppConstants.baseUrl,
        child: const HomeScreen(),
      ),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  AppDatabase? _database;
  AuthService? _authService;
  MetaService? _metaService;
  OfflineRepository? _repository;
  SyncService? _syncService;
  LinkOptionService? _linkOptionService;

  AppConfig? _appConfig;
  bool _isInitialized = false;
  bool _isAuthenticated = false;
  String? _errorMessage;

  Future<int> _getDirtyCount() async {
    if (_repository == null) return 0;
    try {
      final dirty = await _repository!.getDirtyDocuments();
      return dirty.length;
    } catch (e) {
      return 0;
    }
  }

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      _appConfig = AppConfig(
        baseUrl: config.AppConstants.baseUrl,
        doctypes: const [],
        loginConfig: LoginConfig(
          enablePasswordLogin: true,
          enableOAuth: true,
          oauthClientId: config.AppConstants.oauthClientId,
          oauthClientSecret: config.AppConstants.oauthClientSecret,
        ),
      );

      // Initialize SDK and auto-restore session + initial meta/data sync
      final sdk = FrappeSDK(baseUrl: _appConfig!.baseUrl);
      await sdk.initialize(true);

      _database = sdk.database;
      _authService = sdk.auth;
      _metaService = sdk.meta;
      _repository = sdk.repository;
      _syncService = sdk.sync;
      _linkOptionService = sdk.linkOptions;
      _isAuthenticated = sdk.isAuthenticated;

      setState(() {
        _isInitialized = true;
      });
    } catch (e) {
      setState(() {
        _isInitialized = true;
        _errorMessage = e.toString();
      });
    }
  }

  /// Perform initial metadata and data sync for mobile forms.
  ///
  /// 1. Sync doctypes from login response (checkAndSyncDoctypes).
  /// 2. Resync configuration from server (mobile_auth.configuration).
  /// 3. Pull data for all mobile form doctypes so list counts are up to date.
  Future<void> _initialMetaAndDataSync() async {
    if (_metaService == null || _syncService == null) {
      return;
    }

    // Step 1: sync doctypes from stored mobile_form_names
    try {
      await _metaService!.checkAndSyncDoctypes();
    } catch (_) {
      // Ignore, configuration step may still refresh things
    }

    // Step 2: resync configuration from server
    try {
      await _metaService!.resyncMobileConfiguration();
    } catch (_) {
      // If this fails, we still keep the previous configuration
    }

    // Step 3: pull data for all mobile form doctypes
    try {
      final doctypes = await _metaService!.getMobileFormDoctypeNames();
      for (final doctype in doctypes) {
        try {
          await _syncService!.pullSync(doctype: doctype);
        } catch (_) {
          // Skip failing doctypes, continue with others
          continue;
        }
      }
    } catch (_) {
      // Do not block app if data sync fails
    }
  }

  Future<void> _handleLoginSuccess() async {
    if (_authService == null ||
        _authService!.client == null ||
        _database == null) {
      return;
    }

    // Initialize services if not already done
    _metaService ??= MetaService(_authService!.client!, _database!);
    _repository ??= OfflineRepository(_database!);
    _syncService ??= SyncService(
      _authService!.client!,
      _repository!,
      _database!,
    );
    _linkOptionService ??= LinkOptionService(_authService!.client!);

    // Initial metadata + data sync for mobile forms
    await _initialMetaAndDataSync();

    setState(() {
      _isAuthenticated = true;
    });

    if (_appConfig != null && _syncService != null && _metaService != null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Initial sync completed'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
  }

  Future<void> _handleLogout() async {
    if (_authService != null) {
      await _authService!.logout();
    }
    setState(() {
      _isAuthenticated = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (_errorMessage != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Error')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error, color: Colors.red, size: 64),
                const SizedBox(height: 16),
                Text(
                  'Initialization Error',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  _errorMessage!,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 24),
                if (_errorMessage!.contains('libsqlite3.so'))
                  const Text(
                    'Please install SQLite:\nsudo apt-get install libsqlite3-dev',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
              ],
            ),
          ),
        ),
      );
    }

    // Check authentication first (matching frappe_huf pattern)
    if (!_isAuthenticated) {
      if (_authService == null) {
        return const Scaffold(
          body: Center(child: Text('Auth service not initialized')),
        );
      }
      return LoginScreen(
        authService: _authService!,
        appConfig: _appConfig,
        initialBaseUrl: _appConfig?.baseUrl,
        onLoginSuccess: _handleLoginSuccess,
        database: _database,
      );
    }

    // After authentication, ensure services are initialized
    if (_authService == null || _authService!.client == null) {
      return const Scaffold(
        body: Center(child: Text('Auth service not available')),
      );
    }

    // Initialize services if not already done (should happen in _handleLoginSuccess, but double-check)
    if (_metaService == null ||
        _repository == null ||
        _syncService == null ||
        _linkOptionService == null) {
      if (_database != null && _authService!.client != null) {
        _metaService = MetaService(_authService!.client!, _database!);
        _repository = OfflineRepository(_database!);
        _syncService = SyncService(
          _authService!.client!,
          _repository!,
          _database!,
          getMobileUuid: () => _authService!.getOrCreateMobileUuid(),
        );
        _linkOptionService = LinkOptionService(_authService!.client!);
      } else {
        return const Scaffold(
          body: Center(
            child: Text('Services not initialized. Please restart the app.'),
          ),
        );
      }
    }

    if (_appConfig == null) {
      return const Scaffold(body: Center(child: Text('App config not loaded')));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Frappe Mobile SDK'),
        actions: [
          // Sync status button with badge
          if (_syncService != null && _repository != null)
            IconButton(
              icon: Stack(
                children: [
                  const Icon(Icons.sync),
                  // Show badge if there are dirty documents
                  FutureBuilder<int>(
                    future: _getDirtyCount(),
                    builder: (context, snapshot) {
                      final count = snapshot.data ?? 0;
                      if (count == 0) return const SizedBox.shrink();
                      return Positioned(
                        right: 0,
                        top: 0,
                        child: Container(
                          padding: const EdgeInsets.all(2),
                          decoration: BoxDecoration(
                            color: Colors.red,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          constraints: const BoxConstraints(
                            minWidth: 12,
                            minHeight: 12,
                          ),
                          child: Text(
                            count > 9 ? '9+' : '$count',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 8,
                              fontWeight: FontWeight.bold,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => SyncStatusScreen(
                      syncService: _syncService!,
                      repository: _repository!,
                    ),
                  ),
                );
              },
              tooltip: 'Sync Status',
            ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: _handleLogout,
            tooltip: 'Logout',
          ),
        ],
      ),
      body: FutureBuilder<List<String>>(
        future:
            _metaService?.getMobileFormDoctypeNames() ??
            Future.value(<String>[]),
        builder: (context, snapshot) {
          final doctypes = snapshot.data ?? [];
          return DoctypeListScreen(
            appConfig: _appConfig!,
            repository: _repository!,
            doctypes: doctypes.isNotEmpty ? doctypes : null,
            onDoctypeSelected: (doctype) async {
              // Navigate to document list for this doctype
              if (_repository == null ||
                  _metaService == null ||
                  _syncService == null) {
                return;
              }

              // Show loading
              if (mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('Loading...')));
              }

              try {
                final meta = await _metaService!.getMeta(doctype);

                // Try to pull documents from server first (if online)
                if (_syncService != null) {
                  final isOnline = await _syncService!.isOnline();
                  if (isOnline) {
                    try {
                      await _syncService!.pullSync(doctype: doctype);
                    } catch (syncError) {
                      // Continue even if sync fails - show local data
                    }
                  }
                }

                // Get documents from local database (after sync attempt)
                final docs = await _repository!.getDocumentsByDoctype(doctype);

                if (mounted) {
                  final ctx = context;
                  ScaffoldMessenger.of(ctx).hideCurrentSnackBar();
                  Navigator.push(
                    ctx,
                    MaterialPageRoute(
                      builder: (context) => DocumentListScreen(
                        doctype: doctype,
                        meta: meta,
                        repository: _repository!,
                        syncService: _syncService!,
                        metaService: _metaService!,
                        linkOptionService: _linkOptionService,
                        api: _authService?.client,
                        getMobileUuid: () =>
                            _authService!.getOrCreateMobileUuid(),
                        initialDocuments: docs,
                        userRoles: _authService?.roles,
                      ),
                    ),
                  );
                }
              } catch (e) {
                if (mounted) {
                  final ctx = context;
                  ScaffoldMessenger.of(ctx).hideCurrentSnackBar();
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    SnackBar(
                      content: Text(
                        'Error: ${e.toString().split(':').last.trim()}',
                      ),
                      backgroundColor: Colors.red,
                      duration: const Duration(seconds: 5),
                    ),
                  );
                }
              }
            },
            onNewDocument: (doctype) async {
              if (_metaService == null ||
                  _repository == null ||
                  _syncService == null) {
                return;
              }

              // Show loading
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Loading metadata...')),
                );
              }

              try {
                final meta = await _metaService!.getMeta(doctype);
                if (mounted) {
                  final ctx = context;
                  ScaffoldMessenger.of(ctx).hideCurrentSnackBar();
                  Navigator.push(
                    ctx,
                    MaterialPageRoute(
                      builder: (context) => FormScreen(
                        meta: meta,
                        repository: _repository!,
                        syncService: _syncService!,
                        linkOptionService: _linkOptionService,
                        metaService: _metaService,
                        api: _authService?.client,
                        onSaveSuccess: () => Navigator.pop(ctx),
                        getMobileUuid: () =>
                            _authService!.getOrCreateMobileUuid(),
                        // style: DefaultFormStyle.material,
                      ),
                    ),
                  );
                }
              } catch (e) {
                if (mounted) {
                  final ctx = context;
                  ScaffoldMessenger.of(ctx).hideCurrentSnackBar();
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    SnackBar(
                      content: Text(
                        'Failed to load metadata: ${e.toString().split(':').last.trim()}',
                      ),
                      backgroundColor: Colors.red,
                      duration: const Duration(seconds: 5),
                    ),
                  );
                }
              }
            },
          );
        },
      ),
    );
  }
}
