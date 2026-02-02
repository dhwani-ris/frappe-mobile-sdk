import 'package:json_annotation/json_annotation.dart';

part 'app_config.g.dart';

/// Login method configuration (password, OAuth, social).
@JsonSerializable()
class LoginConfig {
  final bool enablePasswordLogin;
  final bool enableOAuth;
  final bool enableSocialLogin;
  final String? oauthClientId;
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

/// Application configuration for Frappe Mobile SDK.
@JsonSerializable()
class AppConfig {
  final String baseUrl;
  final List<String> doctypes;
  final LoginConfig? loginConfig;

  AppConfig({required this.baseUrl, required this.doctypes, this.loginConfig});

  factory AppConfig.fromJson(Map<String, dynamic> json) =>
      _$AppConfigFromJson(json);

  Map<String, dynamic> toJson() => _$AppConfigToJson(this);

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
