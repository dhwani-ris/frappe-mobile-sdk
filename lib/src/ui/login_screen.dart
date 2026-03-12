import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../constants/oauth_constants.dart';
import '../database/app_database.dart';
import '../models/app_config.dart';
import '../services/auth_service.dart';
import 'login_screen_style.dart';

/// Login screen for Frappe (credentials, OAuth, or mobile OTP).
///
/// Login methods and OAuth credentials come from [AppConfig.loginConfig].
/// When [enableMobileLogin] is true in config, provide [sendLoginOtp] and
/// [verifyLoginOtp] (e.g. from SDK) to enable mobile OTP login.
class LoginScreen extends StatefulWidget {
  final AuthService authService;
  final AppConfig? appConfig;
  final String? initialBaseUrl;
  final VoidCallback? onLoginSuccess;

  /// When set, used for password login (e.g. [FrappeSDK.login]) so permissions and locale are applied.
  final Future<Map<String, dynamic>?> Function(
    String username,
    String password,
  )?
  passwordLogin;

  /// When set with [verifyLoginOtp], enables mobile OTP login. E.g. [FrappeSDK.sendLoginOtp].
  final Future<Map<String, dynamic>?> Function(String mobileNo)? sendLoginOtp;

  /// When set with [sendLoginOtp], enables mobile OTP login. E.g. [FrappeSDK.verifyLoginOtp].
  final Future<Map<String, dynamic>?> Function(String tmpId, String otp)?
  verifyLoginOtp;

  final AppDatabase? database;

  /// Optional styling (title, buttons, inputs, etc.). Null uses theme defaults.
  final LoginScreenStyle? style;

  const LoginScreen({
    super.key,
    required this.authService,
    this.appConfig,
    this.initialBaseUrl,
    this.onLoginSuccess,
    this.passwordLogin,
    this.sendLoginOtp,
    this.verifyLoginOtp,
    this.database,
    this.style,
  });

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _baseUrlController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _mobileController = TextEditingController();
  final _otpController = TextEditingController();
  final _appLinks = AppLinks();
  StreamSubscription<Uri>? _linkSubscription;
  bool _isLoading = false;
  String? _errorMessage;
  String? _oauthCodeVerifier;
  String? _otpTmpId;
  bool _otpSent = false;

  /// When true, mobile OTP section is expanded. When password login is disabled, starts true.
  bool _mobileSectionExpanded = false;

  String get _baseUrl {
    if (widget.appConfig != null) return widget.appConfig!.baseUrl;
    return _baseUrlController.text.trim();
  }

  bool get _showBaseUrlInput =>
      widget.appConfig == null && widget.initialBaseUrl == null;

  bool get _enablePasswordLogin =>
      widget.appConfig?.enablePasswordLogin ?? true;

  bool get _enableOAuth => widget.appConfig?.enableOAuth ?? false;

  bool get _enableMobileLogin => widget.appConfig?.enableMobileLogin ?? false;

  bool get _hasMobileOtpCallbacks =>
      widget.sendLoginOtp != null && widget.verifyLoginOtp != null;

  String? get _oauthClientId => widget.appConfig?.oauthClientId;

  String? get _oauthClientSecret => widget.appConfig?.oauthClientSecret;

  @override
  void initState() {
    super.initState();
    if (widget.initialBaseUrl != null && widget.appConfig == null) {
      _baseUrlController.text = widget.initialBaseUrl!;
    }
    // When password login is disabled, show mobile OTP section expanded by default
    _mobileSectionExpanded = !_enablePasswordLogin;
    _checkInitialUri();
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
    _mobileController.dispose();
    _otpController.dispose();
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
      final username = _usernameController.text.trim();
      final password = _passwordController.text;

      if (widget.passwordLogin != null) {
        await widget.passwordLogin!(username, password);
      } else {
        final baseUrl = _baseUrl;
        if (widget.authService.client == null) {
          widget.authService.initialize(baseUrl, database: widget.database);
        }
        if (widget.database == null) {
          throw Exception(
            'Database not set. LoginScreen requires database for stateless login.',
          );
        }
        await widget.authService.login(username, password);
      }
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

  Future<void> _handleSendOtp() async {
    final mobileNo = _mobileController.text.trim();
    if (mobileNo.isEmpty) {
      setState(() => _errorMessage = 'Enter mobile number');
      return;
    }
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _otpSent = false;
      _otpTmpId = null;
    });
    try {
      if (widget.authService.client == null) {
        widget.authService.initialize(_baseUrl, database: widget.database);
      }
      final response = await widget.sendLoginOtp!(mobileNo);
      if (response == null) {
        throw Exception('Send OTP failed');
      }
      final tmpId = response['tmp_id']?.toString();
      if (tmpId == null || tmpId.isEmpty) {
        throw Exception(
          response['message']?.toString() ?? 'No tmp_id in response',
        );
      }
      if (mounted) {
        setState(() {
          _otpTmpId = tmpId;
          _otpSent = true;
          _isLoading = false;
        });
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

  Future<void> _handleVerifyOtp() async {
    final otp = _otpController.text.trim();
    if (otp.isEmpty || _otpTmpId == null) return;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      await widget.verifyLoginOtp!(_otpTmpId!, otp);
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
    final hasAnyLogin =
        _enablePasswordLogin ||
        _enableOAuth ||
        (_enableMobileLogin && _hasMobileOtpCallbacks);
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

    final style = widget.style;
    final padding = style?.padding ?? const EdgeInsets.all(24.0);
    final showOr =
        _enablePasswordLogin &&
        !_mobileSectionExpanded &&
        (_enableMobileLogin && _hasMobileOtpCallbacks || _enableOAuth);

    return Scaffold(
      appBar: AppBar(title: const Text('Frappe Login')),
      body: Center(
        child: SingleChildScrollView(
          padding: padding,
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(
                  Icons.login,
                  size: style?.iconSize ?? 80,
                  color: style?.iconColor ?? Colors.blue,
                ),
                const SizedBox(height: 32),
                Text(
                  'Login to Frappe',
                  textAlign: TextAlign.center,
                  style:
                      style?.titleStyle ??
                      const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                ),
                const SizedBox(height: 32),
                if (_showBaseUrlInput)
                  TextFormField(
                    controller: _baseUrlController,
                    decoration:
                        style?.baseUrlDecoration ??
                        const InputDecoration(
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
                // Password login section (hidden when mobile OTP section is expanded)
                if (_enablePasswordLogin && !_mobileSectionExpanded) ...[
                  TextFormField(
                    controller: _usernameController,
                    decoration:
                        style?.usernameDecoration ??
                        const InputDecoration(
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
                    decoration:
                        style?.passwordDecoration ??
                        const InputDecoration(
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
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _isLoading ? null : _handleLogin,
                      style:
                          style?.loginButtonStyle ??
                          ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            minimumSize: const Size(double.infinity, 48),
                          ),
                      child: _isLoading && !_enableOAuth
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Login'),
                    ),
                  ),
                ],
                // OR divider when password is enabled and at least one other method exists
                if (showOr) ...[
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      const Expanded(child: Divider()),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text(
                          'OR',
                          style:
                              style?.orDividerTextStyle ??
                              Theme.of(context).textTheme.titleSmall?.copyWith(
                                color: Colors.grey,
                              ),
                        ),
                      ),
                      const Expanded(child: Divider()),
                    ],
                  ),
                  const SizedBox(height: 24),
                ],
                // Mobile OTP: either expanded section or single "Login with mobile" button
                if (_enableMobileLogin && _hasMobileOtpCallbacks) ...[
                  if (!_mobileSectionExpanded)
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _isLoading
                            ? null
                            : () =>
                                  setState(() => _mobileSectionExpanded = true),
                        style: style?.mobileButtonStyle,
                        icon: const Icon(Icons.phone),
                        label: const Text('Login with mobile'),
                      ),
                    ),
                  if (_mobileSectionExpanded) ...[
                    if (_enablePasswordLogin)
                      Text(
                        'Login with mobile',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    if (_enablePasswordLogin) const SizedBox(height: 12),
                    TextFormField(
                      controller: _mobileController,
                      decoration:
                          style?.mobileDecoration ??
                          const InputDecoration(
                            labelText: 'Mobile number',
                            hintText: '+15551234567',
                            prefixIcon: Icon(Icons.phone),
                            border: OutlineInputBorder(),
                          ),
                      keyboardType: TextInputType.phone,
                      enabled: !_otpSent && !_isLoading,
                    ),
                    if (!_otpSent) ...[
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton(
                          onPressed: _isLoading ? null : _handleSendOtp,
                          child: const Text('Send OTP'),
                        ),
                      ),
                    ] else ...[
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _otpController,
                        decoration:
                            style?.otpDecoration ??
                            const InputDecoration(
                              labelText: 'OTP',
                              hintText: '123456',
                              prefixIcon: Icon(Icons.pin),
                              border: OutlineInputBorder(),
                            ),
                        keyboardType: TextInputType.number,
                        maxLength: 6,
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: _isLoading ? null : _handleVerifyOtp,
                          child: _isLoading
                              ? const SizedBox(
                                  height: 20,
                                  width: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Text('Verify OTP'),
                        ),
                      ),
                      TextButton(
                        onPressed: _isLoading
                            ? null
                            : () {
                                setState(() {
                                  _otpSent = false;
                                  _otpTmpId = null;
                                  _otpController.clear();
                                });
                              },
                        child: const Text('Change number'),
                      ),
                    ],
                    if (_enablePasswordLogin)
                      TextButton(
                        onPressed: () =>
                            setState(() => _mobileSectionExpanded = false),
                        child: const Text('Back to password'),
                      ),
                  ],
                  if (_enableMobileLogin &&
                      _hasMobileOtpCallbacks &&
                      _enableOAuth)
                    const SizedBox(height: 16),
                ],
                // OAuth button
                if (_enableOAuth)
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.tonalIcon(
                      onPressed: _isLoading ? null : _startOAuth,
                      style:
                          style?.oauthButtonStyle ??
                          FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            minimumSize: const Size(double.infinity, 48),
                          ),
                      icon: const Icon(Icons.login),
                      label: const Text('Login with OAuth'),
                    ),
                  ),
                if (_errorMessage != null) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: style?.errorBackgroundColor ?? Colors.red[50],
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
                            style:
                                style?.errorTextStyle ??
                                const TextStyle(color: Colors.red),
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
              ],
            ),
          ),
        ),
      ),
    );
  }
}
