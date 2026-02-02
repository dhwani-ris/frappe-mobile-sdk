import 'package:json_annotation/json_annotation.dart';

part 'app_config.g.dart';

/// Login method configuration
@JsonSerializable()
class LoginConfig {
  /// Enable username/password login
  final bool enablePasswordLogin;

  /// Enable OAuth 2.0 login
  final bool enableOAuth;

  /// Enable social login (Google, Apple, etc.) - for future use
  final bool enableSocialLogin;

  /// OAuth Client ID (required when enableOAuth is true)
  final String? oauthClientId;

  /// OAuth Client Secret (required for confidential clients)
  final String? oauthClientSecret;

  const LoginConfig({
    this.enablePasswordLogin = true,
    this.enableOAuth = false,
    this.enableSocialLogin = false,
    this.oauthClientId,
    this.oauthClientSecret,
  });

  factory LoginConfig.fromJson(Map<String, dynamic> json) =>
      _$LoginConfigFromJson(json);
  Map<String, dynamic> toJson() => _$LoginConfigToJson(this);
}

/// Application configuration for Frappe Mobile SDK
///
/// Defines base URL, doctypes, and login method options
@JsonSerializable()
class AppConfig {
  /// Frappe server base URL
  final String baseUrl;

  /// List of Doctype names to support offline
  final List<String> doctypes;

  /// Login method configuration (enable/disable password, OAuth)
  final LoginConfig? loginConfig;

  AppConfig({required this.baseUrl, required this.doctypes, this.loginConfig});

  factory AppConfig.fromJson(Map<String, dynamic> json) =>
      _$AppConfigFromJson(json);

  Map<String, dynamic> toJson() => _$AppConfigToJson(this);

  /// Create from JSON file
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
  String? get oauthClientId => loginConfig?.oauthClientId;
  String? get oauthClientSecret => loginConfig?.oauthClientSecret;
}
