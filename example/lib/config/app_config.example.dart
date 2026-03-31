/// Example app configuration file.
///
/// Copy this file to app_config.dart and update with your values.
/// app_config.dart is gitignored and won't be committed.
class AppConstants {
  /// App display name.
  static const String appName = 'Frappe Mobile SDK Demo';

  /// App version shown in UI.
  static const String appVersion = '1.0.0';

  /// Android/iOS package identifier.
  static const String packageName = 'com.example.frappe_mobile_sdk_demo';

  /// Home screen layout mode. Allowed values: 'list' or 'folder'.
  static const String homeScreenLayout = 'list';

  /// Frappe server base URL (with trailing slash)
  static const String baseUrl = 'https://your-site.com/';

  /// OAuth client ID from Frappe OAuth Client settings
  static const String oauthClientId = 'your_oauth_client_id';

  /// OAuth client secret from Frappe OAuth Client settings
  static const String oauthClientSecret = 'your_oauth_client_secret';
}
