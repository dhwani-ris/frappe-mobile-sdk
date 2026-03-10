import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../constants/oauth_constants.dart';
import '../database/app_database.dart';
import '../models/app_config.dart';
import '../services/auth_service.dart';

/// Login screen for Frappe (credentials or OAuth).
///
/// Login methods and OAuth credentials come from [AppConfig.loginConfig].
/// OAuth uses [oauthRedirectUri]; configure this in Frappe OAuth Client.
class LoginScreen extends StatefulWidget {
  final AuthService authService;
  final AppConfig? appConfig;
  final String? initialBaseUrl;
  final VoidCallback? onLoginSuccess;
  final AppDatabase? database;
  /// Pre-fill username (e.g. for demo automation)
  final String? initialUsername;
  /// Pre-fill password (e.g. for demo automation)
  final String? initialPassword;
  /// When true, automatically trigger login after first frame if credentials are pre-filled
  final bool autoLogin;

  const LoginScreen({
    super.key,
    required this.authService,
    this.appConfig,
    this.initialBaseUrl,
    this.onLoginSuccess,
    this.database,
    this.initialUsername,
    this.initialPassword,
    this.autoLogin = false,
  });

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _baseUrlController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _appLinks = AppLinks();
  StreamSubscription<Uri>? _linkSubscription;
  bool _isLoading = false;
  String? _errorMessage;
  String? _oauthCodeVerifier;

  String get _baseUrl {
    if (widget.appConfig != null) return widget.appConfig!.baseUrl;
    return _baseUrlController.text.trim();
  }

  bool get _showBaseUrlInput =>
      widget.appConfig == null && widget.initialBaseUrl == null;

  bool get _enablePasswordLogin =>
      widget.appConfig?.enablePasswordLogin ?? true;

  bool get _enableOAuth => widget.appConfig?.enableOAuth ?? false;

  String? get _oauthClientId => widget.appConfig?.oauthClientId;

  String? get _oauthClientSecret => widget.appConfig?.oauthClientSecret;

  @override
  void initState() {
    super.initState();
    if (widget.initialBaseUrl != null && widget.appConfig == null) {
      _baseUrlController.text = widget.initialBaseUrl!;
    }
    if (widget.initialUsername != null) {
      _usernameController.text = widget.initialUsername!;
    }
    if (widget.initialPassword != null) {
      _passwordController.text = widget.initialPassword!;
    }
    _checkInitialUri();
    if (widget.autoLogin &&
        widget.initialUsername != null &&
        widget.initialUsername!.trim().isNotEmpty &&
        widget.initialPassword != null &&
        widget.initialPassword!.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _handleLogin();
      });
    }
  }

  Future<void> _checkInitialUri() async {
    try {
      final uri = await _appLinks.getInitialLink();
      if (uri != null && mounted) _handleOAuthRedirect(uri);
    } catch (_) {}
  }

  void _listenForOAuthRedirect() {
    _linkSubscription?.cancel();
    _linkSubscription = _appLinks.uriLinkStream.listen((uri) {
      if (mounted) _handleOAuthRedirect(uri);
    });
  }

  void _cancelOAuthListener() {
    _linkSubscription?.cancel();
    _linkSubscription = null;
  }

  Future<void> _handleOAuthRedirect(Uri uri) async {
    if (uri.scheme != 'frappemobilesdk' ||
        uri.host != 'oauth' ||
        uri.path != '/callback') {
      return;
    }
    final code = uri.queryParameters['code'];
    if (code == null || code.isEmpty || _oauthCodeVerifier == null) return;
    final clientId = _oauthClientId;
    if (clientId == null || clientId.isEmpty) return;

    _cancelOAuthListener();
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final success = await widget.authService.loginWithOAuth(
        code: code,
        codeVerifier: _oauthCodeVerifier!,
        clientId: clientId,
        redirectUri: oauthRedirectUri,
        clientSecret: _oauthClientSecret,
      );
      if (mounted) {
        setState(() => _isLoading = false);
        if (success) {
          await Future.delayed(const Duration(milliseconds: 100));
          widget.onLoginSuccess?.call();
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString().replaceAll('Exception: ', '');
          _isLoading = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _cancelOAuthListener();
    _baseUrlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _startOAuth() async {
    final baseUrl = _baseUrl;
    final clientId = _oauthClientId;
    if (baseUrl.isEmpty || clientId == null || clientId.isEmpty) {
      setState(() {
        _errorMessage =
            'OAuth is enabled but oauth_client_id is not set in config';
      });
      return;
    }
    if (widget.authService.client == null) {
      widget.authService.initialize(baseUrl);
    }
    try {
      final map = await AuthService.prepareOAuthLogin(
        baseUrl: baseUrl,
        clientId: clientId,
        redirectUri: oauthRedirectUri,
      );
      final authorizeUrl = map['authorize_url']!;
      _oauthCodeVerifier = map['code_verifier'];
      _listenForOAuthRedirect();
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });
      final uri = Uri.parse(authorizeUrl);
      final canLaunch = await canLaunchUrl(uri);
      if (canLaunch) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        setState(() {
          _errorMessage =
              'Cannot open browser. Add https intent to AndroidManifest queries.';
          _isLoading = false;
        });
        _cancelOAuthListener();
      }
      if (!mounted) return;
    } catch (e) {
      _cancelOAuthListener();
      setState(() {
        _errorMessage = e.toString().replaceAll('Exception: ', '');
        _isLoading = false;
      });
    }
  }

  Future<void> _handleLogin() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final baseUrl = _baseUrl;
      if (widget.authService.client == null) {
        widget.authService.initialize(baseUrl, database: widget.database);
      }

      if (widget.database == null) {
        throw Exception(
          'Database not set. LoginScreen requires database for stateless login.',
        );
      }

      await widget.authService.login(
        _usernameController.text.trim(),
        _passwordController.text,
      );
      if (mounted) {
        await Future.delayed(const Duration(milliseconds: 100));
        widget.onLoginSuccess?.call();
      }
    } catch (e) {
      setState(() {
        _errorMessage = e.toString().replaceAll('Exception: ', '');
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasAnyLogin = _enablePasswordLogin || _enableOAuth;
    if (!hasAnyLogin) {
      return Scaffold(
        appBar: AppBar(title: const Text('Frappe Login')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Text(
              'No login methods enabled. Configure login_config in AppConfig.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Frappe Login')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.login, size: 80, color: Colors.blue),
                const SizedBox(height: 32),
                const Text(
                  'Login to Frappe',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 32),
                if (_showBaseUrlInput)
                  TextFormField(
                    controller: _baseUrlController,
                    decoration: const InputDecoration(
                      labelText: 'Base URL',
                      hintText: 'https://your-site.com',
                      prefixIcon: Icon(Icons.link),
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.url,
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return 'Please enter base URL';
                      }
                      final uri = Uri.tryParse(value);
                      if (uri == null || !uri.hasScheme || !uri.hasAuthority) {
                        return 'Please enter a valid URL';
                      }
                      return null;
                    },
                  ),
                if (_showBaseUrlInput) const SizedBox(height: 16),
                if (_enablePasswordLogin) ...[
                  TextFormField(
                    controller: _usernameController,
                    decoration: const InputDecoration(
                      labelText: 'Username / Email',
                      prefixIcon: Icon(Icons.person),
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.emailAddress,
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return 'Please enter username';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _passwordController,
                    decoration: const InputDecoration(
                      labelText: 'Password',
                      prefixIcon: Icon(Icons.lock),
                      border: OutlineInputBorder(),
                    ),
                    obscureText: true,
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return 'Please enter password';
                      }
                      return null;
                    },
                  ),
                ],
                if (_errorMessage != null) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.red[50],
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.red),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.error, color: Colors.red),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _errorMessage!,
                            style: const TextStyle(color: Colors.red),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                if (_isLoading && _enableOAuth)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Center(
                      child: Column(
                        children: [
                          CircularProgressIndicator(),
                          SizedBox(height: 12),
                          Text(
                            'Complete login in browser, then return here',
                            style: TextStyle(fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (!_isLoading || _enablePasswordLogin) ...[
                  const SizedBox(height: 24),
                  if (_enablePasswordLogin)
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _isLoading ? null : _handleLogin,
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          minimumSize: const Size(double.infinity, 48),
                        ),
                        child: _isLoading && !_enableOAuth
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('Login'),
                      ),
                    ),
                  if (_enablePasswordLogin && _enableOAuth)
                    const SizedBox(height: 16),
                  if (_enableOAuth)
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.tonalIcon(
                        onPressed: _isLoading ? null : _startOAuth,
                        icon: const Icon(Icons.login),
                        label: const Text('Login with OAuth'),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          minimumSize: const Size(double.infinity, 48),
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
