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
        doctypes: config.AppConstants.doctypes,
        loginConfig: LoginConfig(
          enablePasswordLogin: true,
          enableOAuth: true,
          oauthClientId: config.AppConstants.oauthClientId,
          oauthClientSecret: config.AppConstants.oauthClientSecret,
        ),
      );
      _database = await AppDatabase.getInstance();

      // Initialize auth service
      _authService = AuthService();
      if (_appConfig != null) {
        _authService!.initialize(_appConfig!.baseUrl, database: _database);
      }

      // Don't initialize services yet - wait for login
      // Services will be initialized after successful login

      // Try to restore session
      if (_authService != null) {
        _isAuthenticated = await _authService!.restoreSession();

        // Only initialize services and fetch metadata if session restored successfully
        if (_isAuthenticated &&
            _authService!.client != null &&
            _database != null) {
          _metaService = MetaService(_authService!.client!, _database!);
          _repository = OfflineRepository(_database!);
          _syncService = SyncService(
            _authService!.client!,
            _repository!,
            _database!,
          );
          _linkOptionService = LinkOptionService(_authService!.client!);

          // If authenticated, fetch metadata for configured doctypes
          if (_appConfig != null) {
            await _loadMetas();
          }
        }
      }

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

  Future<void> _loadMetas() async {
    if (_appConfig == null || _metaService == null) return;
    try {
      await _metaService!.prefetchToDb(_appConfig!.doctypes);
    } catch (_) {}
  }

  Future<void> _handleLoginSuccess() async {
    if (_authService == null ||
        _authService!.client == null ||
        _database == null) {
      return;
    }

    _metaService = MetaService(_authService!.client!, _database!);
    _repository = OfflineRepository(_database!);
    _syncService = SyncService(_authService!.client!, _repository!, _database!);
    _linkOptionService = LinkOptionService(_authService!.client!);

    setState(() {
      _isAuthenticated = true;
    });

    if (_appConfig != null) {
      await _loadMetas();

      if (_syncService != null && _appConfig!.doctypes.isNotEmpty) {
        try {
          for (final doctype in _appConfig!.doctypes) {
            try {
              await _syncService!.syncDoctype(doctype);
            } catch (e) {
              // Continue with other doctypes
            }
          }
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Initial sync completed'),
                duration: Duration(seconds: 2),
              ),
            );
          }
        } catch (e) {
          // Ignore sync errors
        }
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
      body: DoctypeListScreen(
        appConfig: _appConfig!,
        repository: _repository!,
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
                    documents: docs,
                    repository: _repository!,
                    syncService: _syncService!,
                    metaService: _metaService!,
                    linkOptionService: _linkOptionService,
                    api: _authService?.client,
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
                    api: _authService?.client,
                    onSaveSuccess: () => Navigator.pop(ctx),
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
      ),
    );
  }
}

class DocumentListScreen extends StatefulWidget {
  final String doctype;
  final DocTypeMeta meta;
  final List<Document> documents;
  final OfflineRepository repository;
  final SyncService syncService;
  final MetaService metaService;
  final LinkOptionService? linkOptionService;
  final FrappeClient? api;

  const DocumentListScreen({
    super.key,
    required this.doctype,
    required this.meta,
    required this.documents,
    required this.repository,
    required this.syncService,
    required this.metaService,
    this.linkOptionService,
    this.api,
  });

  @override
  State<DocumentListScreen> createState() => _DocumentListScreenState();
}

class _DocumentListScreenState extends State<DocumentListScreen> {
  List<Document> _documents = [];
  final bool _isLoading = false;
  bool _isSyncing = false;

  @override
  void initState() {
    super.initState();
    _documents = widget.documents;
    // Pull documents from server on first load
    _pullDocuments();
  }

  Future<void> _pullDocuments() async {
    if (_isSyncing) return;

    setState(() {
      _isSyncing = true;
    });

    try {
      final isOnline = await widget.syncService.isOnline();
      if (isOnline) {
        await widget.syncService.pullSync(doctype: widget.doctype);
      }

      final docs = await widget.repository.getDocumentsByDoctype(
        widget.doctype,
      );
      setState(() {
        _documents = docs;
      });
    } catch (e) {
      final docs = await widget.repository.getDocumentsByDoctype(
        widget.doctype,
      );
      setState(() {
        _documents = docs;
      });
    } finally {
      setState(() {
        _isSyncing = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.meta.label ?? widget.doctype),
        actions: [
          if (_isSyncing)
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _pullDocuments,
              tooltip: 'Refresh',
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _documents.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.inbox, size: 64, color: Colors.grey),
                  const SizedBox(height: 16),
                  const Text('No documents found'),
                  const SizedBox(height: 8),
                  Text(
                    'Pull down to refresh or create a new document',
                    style: Theme.of(context).textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    onPressed: _pullDocuments,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Refresh from Server'),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => FormScreen(
                            meta: widget.meta,
                            repository: widget.repository,
                            syncService: widget.syncService,
                            api: widget.api,
                            onSaveSuccess: () {
                              Navigator.pop(context);
                              _pullDocuments();
                            },
                          ),
                        ),
                      );
                    },
                    icon: const Icon(Icons.add),
                    label: const Text('Create New'),
                  ),
                ],
              ),
            )
          : RefreshIndicator(
              onRefresh: _pullDocuments,
              child: ListView.builder(
                itemCount: _documents.length,
                itemBuilder: (context, index) {
                  final doc = _documents[index];

                  // Try to get display text from listViewFields first
                  String displayText = '';
                  final listFields = widget.meta.listViewFields;
                  if (listFields.isNotEmpty) {
                    displayText = listFields
                        .map((f) => doc.data[f.fieldname]?.toString() ?? '')
                        .where((s) => s.isNotEmpty)
                        .join(' - ');
                  }

                  // Fallback to common title fields if listViewFields is empty
                  if (displayText.isEmpty) {
                    // Try common title field names
                    for (final fieldName in [
                      'name',
                      'title',
                      'full_name',
                      'customer_name',
                      'supplier_name',
                      'item_name',
                      'item_code',
                    ]) {
                      if (doc.data.containsKey(fieldName) &&
                          doc.data[fieldName] != null) {
                        displayText = doc.data[fieldName].toString();
                        break;
                      }
                    }
                  }

                  // Final fallback to serverId or localId
                  if (displayText.isEmpty) {
                    displayText = doc.serverId ?? doc.localId;
                  }

                  return ListTile(
                    title: Text(displayText.isEmpty ? 'Untitled' : displayText),
                    subtitle: Text(
                      doc.serverId != null
                          ? 'ID: ${doc.serverId}'
                          : 'Local (not synced)',
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (doc.status == 'dirty')
                          const Icon(
                            Icons.cloud_upload,
                            color: Colors.orange,
                            size: 20,
                          ),
                        const Icon(Icons.chevron_right),
                      ],
                    ),
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => FormScreen(
                            meta: widget.meta,
                            document: doc,
                            repository: widget.repository,
                            syncService: widget.syncService,
                            linkOptionService: widget.linkOptionService,
                            api: widget.api,
                            onSaveSuccess: () {
                              Navigator.pop(context);
                              _pullDocuments();
                            },
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => FormScreen(
                meta: widget.meta,
                repository: widget.repository,
                syncService: widget.syncService,
                api: widget.api,
                onSaveSuccess: () {
                  Navigator.pop(context);
                  _pullDocuments();
                },
              ),
            ),
          );
        },
        child: const Icon(Icons.add),
      ),
    );
  }
}
