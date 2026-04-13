# Setup

This file is the primary reference for **Installation**, **Configuration**, and **Quick Start**.

## Prerequisites (server-side)

Apps built with this SDK require the companion server app **Frappe Mobile Control** on your Frappe/ERPNext server:

- Repo: `https://github.com/dhwani-ris/frappe_mobile_control`
- It provides mobile endpoints like `mobile_auth.*` and app status checks (`mobile_auth.app_status`).

## Installation

Add the SDK to your Flutter app’s `pubspec.yaml`:

```yaml
dependencies:
  flutter:
    sdk: flutter

  frappe_mobile_sdk:
    git:
      url: https://github.com/dhwani-ris/frappe-mobile-sdk
      ref: main
```

Or use a local path while developing:

```yaml
dependencies:
  frappe_mobile_sdk:
    path: ../frappe_mobile_sdk
```

Then run:

```bash
flutter pub get
```

## Configuration

Create a centralized config file to store your app constants (base URL, OAuth credentials, doctypes, etc.).

The example app uses `example/lib/config/app_config.dart`. A safe pattern is to commit an example template (like `app_config.example.dart`) and gitignore the real config.

Example:

```dart
class AppConstants {
  /// Frappe server base URL (with trailing slash)
  static const String baseUrl = 'https://your-site.com/';

  /// OAuth client ID from Frappe OAuth Client settings
  static const String oauthClientId = 'your_oauth_client_id';

  /// OAuth client secret from Frappe OAuth Client settings
  static const String oauthClientSecret = 'your_oauth_client_secret';
}
```

Use it when wiring your app:

```dart
import 'config/app_config.dart' as config;
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';

MaterialApp(
  home: FrappeAppGuard(
    baseUrl: config.AppConstants.baseUrl,
    child: YourHomeWidget(),
  ),
);
```

## Social Login (OAuth) Configuration

Frappe social login in this SDK is handled through OAuth 2.0 (authorization code + PKCE). In practice:

- The mobile app starts OAuth.
- Frappe shows its login page (including configured social providers like Google/GitHub/Microsoft).
- Frappe redirects back to the app with an authorization code.
- The SDK exchanges that code for tokens and signs the user in.

### Important behavior in this SDK

- Use `enableOAuth: true` for OAuth login.
- Use `enableSocialLogin: true` to show provider-direct social buttons.
- Social buttons use OAuth internally and can skip the extra provider click.
- Provider list can be auto-discovered from backend.

### 1) Configure Frappe server

1. Install and configure the OAuth provider in Frappe.
2. Create an OAuth client in Frappe.
3. Set redirect URI exactly to:
   - `frappemobilesdk://oauth/callback`
4. Configure social providers in Frappe (Social Login Key) for OAuth-backed SSO.
5. Expose backend methods in your mobile app server layer:
   - `mobile_auth.get_social_login_providers`
   - `mobile_auth.get_social_authorize_url`

### 2) Configure Flutter app login config

```dart
final appConfig = AppConfig(
  baseUrl: config.AppConstants.baseUrl,
  doctypes: const [],
  loginConfig: LoginConfig(
    enablePasswordLogin: true, // optional
    enableMobileLogin: true,   // optional
    enableOAuth: true,         // required for SSO/social via Frappe
    enableSocialLogin: true,   // enables provider-direct buttons
    autoDiscoverSocialProviders: true,
    socialProviders: [
      SocialProviderConfig(id: 'google', label: 'Google'),
      // optional fallback list if backend discovery is unavailable
    ],
    oauthClientId: config.AppConstants.oauthClientId,
    oauthClientSecret: config.AppConstants.oauthClientSecret, // only if your OAuth client requires it
  ),
);
```

### 3) Wire LoginScreen

```dart
LoginScreen(
  authService: sdk.auth,
  database: sdk.database,
  appConfig: appConfig,
  onLoginSuccess: () async {
    await sdk.checkAndSyncDoctypes();
    await sdk.resyncMobileConfiguration();
  },
  passwordLogin: (u, p) => sdk.login(u, p),
  sendLoginOtp: (m) => sdk.sendLoginOtp(m),
  verifyLoginOtp: (t, o) => sdk.verifyLoginOtp(t, o),
)
```

### 4) Android deep-link setup

Add this inside your main activity in `AndroidManifest.xml`:

```xml
<intent-filter>
  <action android:name="android.intent.action.VIEW" />
  <category android:name="android.intent.category.DEFAULT" />
  <category android:name="android.intent.category.BROWSABLE" />
  <data
      android:scheme="frappemobilesdk"
      android:host="oauth"
      android:pathPrefix="/callback" />
</intent-filter>
```

For Android 11+, add browser visibility in `<queries>`:

```xml
<intent>
  <action android:name="android.intent.action.VIEW" />
  <data android:scheme="https" />
</intent>
```

### 5) iOS deep-link setup

Add to `Info.plist`:

```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLSchemes</key>
    <array>
      <string>frappemobilesdk</string>
    </array>
  </dict>
</array>
```

### 6) End-to-end flow

1. User taps `Continue with Google` (or another provider) or `Login with OAuth`.
2. Browser opens Frappe authorize URL.
3. User signs in using Frappe or a social provider configured in Frappe.
4. Frappe redirects to `frappemobilesdk://oauth/callback?code=...`.
5. SDK exchanges code for token and authenticates user.

### Troubleshooting

- `OAuth is enabled but oauth_client_id is not set in config`
  - Set `oauthClientId` in `LoginConfig`.
- App does not return from browser
  - Verify Android/iOS deep-link configuration.
- `401 Invalid authentication token` after OAuth
  - Ensure your Frappe backend accepts OAuth bearer tokens for `mobile_auth.*` endpoints.
- OAuth opens but social providers are missing
  - Configure Social Login Key/provider settings on the Frappe server side.
  - Verify backend `mobile_auth.get_social_login_providers` returns enabled providers.

## Quick start

Basic initialization with `FrappeSDK`:

```dart
import 'package:flutter/material.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final sdk = FrappeSDK(baseUrl: 'https://your-frappe-site.com/');
  // autoRestoreAndSync = true tries to restore a previous session and run initial sync
  await sdk.initialize(true);

  runApp(MyApp(sdk: sdk));
}

class MyApp extends StatelessWidget {
  final FrappeSDK sdk;
  const MyApp({super.key, required this.sdk});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Frappe Mobile App',
      home: HomeScreen(sdk: sdk),
    );
  }
}
```

## App status guard (`FrappeAppGuard`)

`FrappeAppGuard` calls `/api/v2/method/mobile_auth.app_status` on launch to:

- Block app access if `enabled == false` or API returns 417/404
- Show a force-update screen when package name / version mismatch
- Redirect users to the Play Store / App Store (or a custom store URL)

```dart
import 'config/app_config.dart' as config;
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';

MaterialApp(
  home: FrappeAppGuard(
    baseUrl: config.AppConstants.baseUrl,
    child: const HomeScreen(),
  ),
);
```


