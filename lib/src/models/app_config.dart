/// Login method configuration (password, OAuth, social, mobile OTP).
class LoginConfig {
  final bool enablePasswordLogin;
  final bool enableOAuth;
  final bool enableSocialLogin;

  /// When true, show "Login with mobile" and use send_login_otp / verify_login_otp.
  final bool enableMobileLogin;
  final String? oauthClientId;
  final String? oauthClientSecret;

  const LoginConfig({
    this.enablePasswordLogin = true,
    this.enableOAuth = false,
    this.enableSocialLogin = false,
    this.enableMobileLogin = false,
    this.oauthClientId,
    this.oauthClientSecret,
  });

  factory LoginConfig.fromJson(Map<String, dynamic> json) {
    return LoginConfig(
      enablePasswordLogin: json['enablePasswordLogin'] as bool? ?? true,
      enableOAuth: json['enableOAuth'] as bool? ?? false,
      enableSocialLogin: json['enableSocialLogin'] as bool? ?? false,
      enableMobileLogin: json['enableMobileLogin'] as bool? ?? false,
      oauthClientId: json['oauthClientId'] as String?,
      oauthClientSecret: json['oauthClientSecret'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'enablePasswordLogin': enablePasswordLogin,
      'enableOAuth': enableOAuth,
      'enableSocialLogin': enableSocialLogin,
      'enableMobileLogin': enableMobileLogin,
      if (oauthClientId != null) 'oauthClientId': oauthClientId,
      if (oauthClientSecret != null) 'oauthClientSecret': oauthClientSecret,
    };
  }
}

/// Application configuration for Frappe Mobile SDK.
class AppConfig {
  final String baseUrl;
  final List<String> doctypes;
  final LoginConfig? loginConfig;

  AppConfig({required this.baseUrl, required this.doctypes, this.loginConfig});

  factory AppConfig.fromJson(Map<String, dynamic> json) {
    return AppConfig(
      baseUrl: json['baseUrl'] as String,
      doctypes:
          (json['doctypes'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
      loginConfig: json['loginConfig'] != null
          ? LoginConfig.fromJson(json['loginConfig'] as Map<String, dynamic>)
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'baseUrl': baseUrl,
      'doctypes': doctypes,
      if (loginConfig != null) 'loginConfig': loginConfig!.toJson(),
    };
  }

  /// Builds [AppConfig] from a JSON map (supports snake_case and camelCase).
  static AppConfig fromJsonFile(Map<String, dynamic> json) {
    final login = json['login_config'] ?? json['loginConfig'];
    LoginConfig? loginConfig;
    if (login is Map<String, dynamic>) {
      loginConfig = LoginConfig(
        enablePasswordLogin:
            login['enable_password_login'] as bool? ??
            login['enablePasswordLogin'] as bool? ??
            true,
        enableOAuth:
            login['enable_oauth'] as bool? ??
            login['enableOAuth'] as bool? ??
            false,
        enableSocialLogin:
            login['enable_social_login'] as bool? ??
            login['enableSocialLogin'] as bool? ??
            false,
        enableMobileLogin:
            login['enable_mobile_login'] as bool? ??
            login['enableMobileLogin'] as bool? ??
            false,
        oauthClientId:
            login['oauth_client_id'] as String? ??
            login['oauthClientId'] as String?,
        oauthClientSecret:
            login['oauth_client_secret'] as String? ??
            login['oauthClientSecret'] as String?,
      );
    }
    return AppConfig(
      baseUrl: json['base_url'] as String? ?? json['baseUrl'] as String? ?? '',
      doctypes:
          (json['doctypes'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
      loginConfig: loginConfig,
    );
  }

  bool get enablePasswordLogin => loginConfig?.enablePasswordLogin ?? true;
  bool get enableOAuth => loginConfig?.enableOAuth ?? false;
  bool get enableSocialLogin => loginConfig?.enableSocialLogin ?? false;
  bool get enableMobileLogin => loginConfig?.enableMobileLogin ?? false;
  String? get oauthClientId => loginConfig?.oauthClientId;
  String? get oauthClientSecret => loginConfig?.oauthClientSecret;
}
