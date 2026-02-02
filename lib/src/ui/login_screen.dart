import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/auth_service.dart';

/// Login screen for Frappe authentication (credentials or OAuth)
class LoginScreen extends StatefulWidget {
  final AuthService authService;
  final String? initialBaseUrl;
  final VoidCallback? onLoginSuccess;

  const LoginScreen({
    super.key,
    required this.authService,
    this.initialBaseUrl,
    this.onLoginSuccess,
  });

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _baseUrlController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _oauthClientIdController = TextEditingController();
  final _oauthRedirectController = TextEditingController(
    text: 'myapp://oauth/callback',
  );
  bool _isLoading = false;
  String? _errorMessage;
  bool _showBaseUrl = true;
  String? _oauthCodeVerifier;
  bool _showOAuthSection = false;

  @override
  void initState() {
    super.initState();
    if (widget.initialBaseUrl != null) {
      _baseUrlController.text = widget.initialBaseUrl!;
      _showBaseUrl = false;
    }
  }

  @override
  void dispose() {
    _baseUrlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _oauthClientIdController.dispose();
    _oauthRedirectController.dispose();
    super.dispose();
  }

  Future<void> _startOAuth() async {
    final baseUrl = _baseUrlController.text.trim();
    final clientId = _oauthClientIdController.text.trim();
    final redirectUri = _oauthRedirectController.text.trim();
    if (baseUrl.isEmpty || clientId.isEmpty || redirectUri.isEmpty) {
      setState(() {
        _errorMessage =
            'Enter Base URL, OAuth Client ID and Redirect URI for OAuth';
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
        redirectUri: redirectUri,
      );
      final authorizeUrl = map['authorize_url']!;
      _oauthCodeVerifier = map['code_verifier'];
      if (await canLaunchUrl(Uri.parse(authorizeUrl))) {
        await launchUrl(
          Uri.parse(authorizeUrl),
          mode: LaunchMode.externalApplication,
        );
      }
      if (!mounted) return;
      _showOAuthCodeDialog(authorizeUrl);
    } catch (e) {
      setState(() {
        _errorMessage = e.toString().replaceAll('Exception: ', '');
      });
    }
  }

  void _showOAuthCodeDialog(String authorizeUrl) {
    final codeController = TextEditingController();
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('OAuth - Paste code'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'After authorizing in the browser you will be redirected. Copy the "code" from the redirect URL and paste it below.',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 16),
              TextButton.icon(
                onPressed: () async {
                  if (await canLaunchUrl(Uri.parse(authorizeUrl))) {
                    await launchUrl(
                      Uri.parse(authorizeUrl),
                      mode: LaunchMode.externalApplication,
                    );
                  }
                },
                icon: const Icon(Icons.open_in_browser),
                label: const Text('Open in browser again'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: codeController,
                decoration: const InputDecoration(
                  labelText: 'Authorization code',
                  hintText: 'Paste code from redirect URL',
                  border: OutlineInputBorder(),
                ),
                maxLines: 2,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              final code = codeController.text.trim();
              if (code.isEmpty || _oauthCodeVerifier == null) {
                return;
              }
              Navigator.pop(ctx);
              setState(() {
                _isLoading = true;
                _errorMessage = null;
              });
              try {
                final clientId = _oauthClientIdController.text.trim();
                final redirectUri = _oauthRedirectController.text.trim();
                final success = await widget.authService.loginWithOAuth(
                  code: code,
                  codeVerifier: _oauthCodeVerifier!,
                  clientId: clientId,
                  redirectUri: redirectUri,
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
            },
            child: const Text('Complete Login'),
          ),
        ],
      ),
    );
  }

  Future<void> _handleLogin() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final baseUrl = _baseUrlController.text.trim();

      // Initialize if not already done
      if (widget.authService.client == null) {
        widget.authService.initialize(baseUrl);
      }

      final success = await widget.authService.login(
        _usernameController.text.trim(),
        _passwordController.text,
      );

      if (success && mounted) {
        // Wait a bit to ensure session is established
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
                if (_showBaseUrl)
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
                if (_showBaseUrl) const SizedBox(height: 16),
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
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _isLoading ? null : _handleLogin,
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      minimumSize: const Size(double.infinity, 48),
                    ),
                    child: _isLoading
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Login'),
                  ),
                ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: () =>
                      setState(() => _showOAuthSection = !_showOAuthSection),
                  icon: Icon(
                    _showOAuthSection ? Icons.expand_less : Icons.expand_more,
                  ),
                  label: Text(
                    _showOAuthSection ? 'Hide OAuth' : 'Login with OAuth',
                  ),
                ),
                if (_showOAuthSection) ...[
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _oauthClientIdController,
                    decoration: const InputDecoration(
                      labelText: 'OAuth Client ID',
                      hintText: 'From Frappe OAuth Client',
                      prefixIcon: Icon(Icons.vpn_key),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _oauthRedirectController,
                    decoration: const InputDecoration(
                      labelText: 'Redirect URI',
                      hintText: 'e.g. myapp://oauth/callback',
                      prefixIcon: Icon(Icons.link),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
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
