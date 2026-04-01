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


