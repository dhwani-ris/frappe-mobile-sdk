# Frappe Mobile SDK

Flutter package for Frappe integration with direct API access, dynamic form rendering, and offline-first architecture.

## ✨ Features

- ✅ **Stateless Login** - Token-based authentication via `mobile_auth.login` API
- ✅ **Keep User Logged In** - Tokens persist in database, automatic session restore
- ✅ **Auto Token Refresh** - Automatic token refresh on expiry (401 errors)
- ✅ **Frappe API Access** - Auth, CRUD, file upload via `FrappeClient`
- ✅ **Dynamic Form Renderer** - Auto-generate forms from Frappe metadata
- ✅ **Offline-First** - Full offline capability with SQLite
- ✅ **Bi-directional Sync** - Push/pull sync with conflict resolution
- ✅ **Customizable Styling** - Default styles + full customization support

## 📋 Prerequisites

### Server-Side Setup (Required)

Before using this SDK, you need to install the **Frappe Mobile Control** app on your Frappe/ERPNext server. This app provides mobile-specific APIs including app status checking, version control, and mobile app configuration.

**Installation:**

1. **Install via Git** (recommended):
   ```bash
   cd /path/to/your/frappe-bench
   bench get-app https://github.com/dhwani-ris/frappe_mobile_control
   bench install-app frappe_mobile_control
   bench migrate
   ```

2. **Or install manually**:
   - Clone the repository: `git clone https://github.com/dhwani-ris/frappe_mobile_control`
   - Follow the installation instructions in the repository

**Repository**: [https://github.com/dhwani-ris/frappe_mobile_control](https://github.com/dhwani-ris/frappe_mobile_control)

## 🚀 Quick Start

### Installation

```yaml
dependencies:
  frappe_mobile_sdk:
    git:
      url: https://github.com/dhwani-ris/frappe-mobile-sdk
      ref: main
```

### Configuration

Create a centralized config file to store your app constants (base URL, OAuth credentials, etc.). This file is gitignored to keep sensitive data out of version control.

1. **Create config file**: Copy the example template:
   ```bash
   cp lib/config/app_config.example.dart lib/config/app_config.dart
   ```

2. **Update config values** in `lib/config/app_config.dart`:
   ```dart
   class AppConstants {
     /// Frappe server base URL (with trailing slash)
     static const String baseUrl = 'https://your-site.com/';
     
     /// OAuth client ID from Frappe OAuth Client settings
     static const String oauthClientId = 'your_oauth_client_id';
     
     /// OAuth client secret from Frappe OAuth Client settings
     static const String oauthClientSecret = 'your_oauth_client_secret';
     
     /// List of doctypes to sync
     static const List<String> doctypes = ['Customer', 'Lead'];
   }
   ```

3. **Use in your app**:
   ```dart
   import 'config/app_config.dart' as config;
   
   // Wrap your app with FrappeAppGuard (checks app status on launch)
   MaterialApp(
     home: FrappeAppGuard(
       baseUrl: config.AppConstants.baseUrl,
       child: YourHomeWidget(),
     ),
   )
   
   // Use in AppConfig
   AppConfig(
     baseUrl: config.AppConstants.baseUrl,
     doctypes: config.AppConstants.doctypes,
     loginConfig: LoginConfig(
       enableOAuth: true,
       oauthClientId: config.AppConstants.oauthClientId,
       oauthClientSecret: config.AppConstants.oauthClientSecret,
     ),
   )
   ```

**Note**: The `app_config.dart` file is automatically gitignored. Only `app_config.example.dart` is committed to the repository.

### App Status Check (FrappeAppGuard)

The SDK includes automatic app status checking via `FrappeAppGuard`. This widget:
- Checks server-side app configuration on launch (`/api/v2/method/mobile_auth.app_status`)
- Blocks app access if `enabled == false` or API returns 417/404
- Shows force update screen if package name or version mismatch detected
- Automatically redirects to Play Store (Android) or App Store (iOS) for updates

**Note**: Requires [Frappe Mobile Control](https://github.com/dhwani-ris/frappe_mobile_control) app installed on your Frappe server (see [Prerequisites](#-prerequisites) above).

**Required**: Wrap your app's root widget with `FrappeAppGuard`:
```dart
MaterialApp(
  home: FrappeAppGuard(
    baseUrl: config.AppConstants.baseUrl,
    child: YourHomeWidget(),
  ),
)
```

### 1. API Usage (No Form Renderer)

```dart
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';

// Initialize database (required for stateless login)
final database = await AppDatabase.getInstance();

// Initialize client with database
final client = FrappeClient('https://your-frappe-site.com');
final authService = AuthService();
authService.initialize('https://your-frappe-site.com', database: database);

// Login (stateless - tokens stored in database)
final loginResponse = await authService.login('username', 'password');
// Returns: { access_token, refresh_token, user, full_name, mobile_form_names }

// Restore session on app launch (keeps user logged in)
final isAuthenticated = await authService.restoreSession();

// CRUD Operations
final doc = await client.document.createDocument('Customer', {
  'customer_name': 'John Doe',
  'email': 'john@example.com',
});

await client.document.updateDocument('Customer', doc['name'], {
  'phone': '1234567890',
});

final customer = await client.doctype.getByName('Customer', doc['name']);
final customers = await client.doctype.list('Customer', fields: ['*']);

await client.document.deleteDocument('Customer', doc['name']);

// File Upload
final file = File('/path/to/file.pdf');
final uploaded = await client.attachment.uploadFile(file);

// Query Builder
final todos = await client.doc('ToDo')
  .where('status', 'Open')
  .orderBy('creation', descending: true)
  .limit(10)
  .get();
```

### 2. Form Renderer Usage

```dart
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';

// Initialize SDK (database is created automatically)
final sdk = FrappeSDK(
  baseUrl: 'https://your-frappe-site.com',
  doctypes: ['Customer', 'Lead', 'Item'],
);

await sdk.initialize();

// Login (stateless - tokens stored in database automatically)
final loginResponse = await sdk.login('username', 'password');
// Returns: { access_token, refresh_token, user, full_name, mobile_form_names }

// User stays logged in automatically - tokens persist in database
// On app restart, call restoreSession() to restore login state

// Option A: Use Form Renderer Helper
final renderer = FrappeFormRenderer(
  sdk: sdk,
  style: DefaultFormStyle.standard, // or .compact, .material
);

// Render form widget
final formWidget = await renderer.renderForm(
  'Customer',
  onSubmit: (data) async {
    await sdk.repository.createDocument(doctype: 'Customer', data: data);
    await sdk.sync.pushSync(doctype: 'Customer');
  },
);

// Option B: Use FormScreen directly
Navigator.push(
  context,
  MaterialPageRoute(
    builder: (context) => FormScreen(
      meta: await sdk.meta.getMeta('Customer'),
      repository: sdk.repository,
      syncService: sdk.sync,
      linkOptionService: sdk.linkOptions,
    ),
  ),
);

// Option C: Use FrappeFormBuilder directly
FrappeFormBuilder(
  meta: await sdk.meta.getMeta('Customer'),
  onSubmit: (data) async {
    // Handle submission
  },
  style: DefaultFormStyle.standard,
)
```

### 3. Custom Forms Using Same APIs

```dart
// Use FrappeClient for any custom form implementation
final client = FrappeSDK(...).api;

// Your custom form widget
class CustomCustomerForm extends StatefulWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TextField(
          onChanged: (value) => _data['customer_name'] = value,
        ),
        ElevatedButton(
          onPressed: () async {
            // Use same API
            await client.document.createDocument('Customer', _data);
          },
          child: Text('Save'),
        ),
      ],
    );
  }
}
```

## OAuth 2.0 Login

OAuth uses a **system-defined redirect URI** so you can configure it once in Frappe:

1. **Redirect URI**: `frappemobilesdk://oauth/callback` (constant: `oauthRedirectUri`)
2. **Frappe setup**: Setup → Integrations → OAuth Provider → Create OAuth Client → set Redirect URI to the above
3. **App config**: Add OAuth credentials to your `app_config.dart` (see [Configuration](#configuration) above):
```dart
// In app_config.dart
class AppConstants {
  static const String oauthClientId = 'your-frappe-oauth-client-id';
  static const String oauthClientSecret = 'your-client-secret';
}

// Use in AppConfig
loginConfig: LoginConfig(
  enableOAuth: true,
  oauthClientId: config.AppConstants.oauthClientId,
  oauthClientSecret: config.AppConstants.oauthClientSecret, // Required for confidential clients
),
```

4. **Android**: Add to `AndroidManifest.xml`:
   - OAuth redirect intent (inside `<activity>`):
```xml
<intent-filter>
  <action android:name="android.intent.action.VIEW"/>
  <category android:name="android.intent.category.DEFAULT"/>
  <category android:name="android.intent.category.BROWSABLE"/>
  <data android:scheme="frappemobilesdk" android:host="oauth" android:pathPrefix="/callback"/>
</intent-filter>
```
   - Package visibility for browser (inside `<queries>`, required on Android 11+):
```xml
<intent>
  <action android:name="android.intent.action.VIEW"/>
  <data android:scheme="https"/>
</intent>
```

5. **iOS**: Add to `Info.plist` under `CFBundleURLTypes`:
```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLSchemes</key>
    <array><string>frappemobilesdk</string></array>
    <key>CFBundleURLName</key>
    <string>OAuth Callback</string>
  </dict>
</array>
```

Flow: User taps "Login with OAuth" → browser opens → user authorizes → app reopens automatically with tokens. Tokens are stored in secure storage. On 401, refresh token is used automatically; if refresh fails, user must re-login.

## 🔐 Stateless Login & Keep User Logged In

The SDK uses **stateless login** via `mobile_auth.login` API. Tokens are automatically stored in the database and persist across app restarts.

### Login Flow

```dart
// Initialize with database (required)
final database = await AppDatabase.getInstance();
final authService = AuthService();
authService.initialize(baseUrl, database: database);

// Login - tokens stored in database automatically
final response = await authService.login(username, password);
// Response includes: access_token, refresh_token, user, full_name, mobile_form_names

// User stays logged in - tokens persist in database
```

### Restore Session (Keep User Logged In)

```dart
// On app launch, restore session from database
final isAuthenticated = await authService.restoreSession();

if (isAuthenticated) {
  // User is logged in - proceed to main app
} else {
  // Show login screen
}
```

**How it works:**
- ✅ **Login**: Tokens stored in database automatically
- ✅ **App restart**: `restoreSession()` finds tokens → user stays logged in
- ✅ **Token expiry**: On 401 error, automatically refreshes using `refresh_token`
- ✅ **Logout**: Clears tokens from database → user must login again

**Priority order** (in `restoreSession()`):
1. Mobile auth tokens (from database) - **Primary method**
2. OAuth tokens (from secure storage)
3. API key (from secure storage)

### Using LoginScreen Widget

The `LoginScreen` widget automatically uses stateless login when database is provided:

```dart
final database = await AppDatabase.getInstance();
final authService = AuthService();
authService.initialize(baseUrl, database: database);

// LoginScreen automatically uses mobile_auth.login
LoginScreen(
  authService: authService,
  database: database, // Required for stateless login
  appConfig: appConfig,
  onLoginSuccess: () {
    // User logged in - tokens stored in database
    // Navigate to main app
  },
)
```

**Note**: `LoginScreen` requires `database` parameter. Without it, login will fail with an error.

## 📚 API Reference

### AuthService (Stateless Login)

```dart
// Initialize with database (required for stateless login)
final database = await AppDatabase.getInstance();
final authService = AuthService();
authService.initialize(baseUrl, database: database);

// Login (stateless - uses mobile_auth.login API)
final response = await authService.login(username, password);
// Returns: { access_token, refresh_token, user, full_name, mobile_form_names }

// Restore session (keeps user logged in)
final isAuthenticated = await authService.restoreSession();

// API key login (alternative)
await authService.loginWithApiKey(apiKey, apiSecret);

// OAuth login
await authService.loginWithOAuth(...);

// Logout (clears tokens from database)
await authService.logout();

// Documents
client.document.createDocument(doctype, data);
client.document.updateDocument(doctype, name, data);
client.document.deleteDocument(doctype, name);
client.document.submitDocument(doctype, name);
client.document.cancelDocument(doctype, name);

// DocType Operations
client.doctype.getDocTypeMeta(doctype);
client.doctype.list(doctype, fields: ['*'], filters: [...]);
client.doctype.getByName(doctype, name);

// File Upload
client.attachment.uploadFile(file, doctype: 'Customer', docname: 'CUST-001');

// Query Builder
client.doc('ToDo').where('status', 'Open').get();
```

### FrappeSDK (High-Level)

```dart
final sdk = FrappeSDK(baseUrl: '...', doctypes: ['...']);
await sdk.initialize(); // Database created automatically

// Login (stateless - tokens stored in database)
final loginResponse = await sdk.login(username, password);
// Returns: { access_token, refresh_token, user, full_name, mobile_form_names }

// User stays logged in automatically
// On app restart, call sdk.auth.restoreSession() to restore login state

// Access services
sdk.api          // FrappeClient
sdk.auth         // AuthService
sdk.meta         // MetaService
sdk.sync         // SyncService
sdk.repository   // OfflineRepository
sdk.linkOptions  // LinkOptionService
```

### Form Styling

```dart
// Use predefined styles
DefaultFormStyle.standard  // Standard Material 3 style
DefaultFormStyle.compact    // Compact style
DefaultFormStyle.material   // Material Design style

// Or create custom style
FrappeFormStyle(
  labelStyle: TextStyle(fontSize: 16),
  sectionPadding: EdgeInsets.all(20),
  fieldDecoration: (field) => InputDecoration(...),
)
```

## 🎨 Styling Options

The package provides three default styles:

- **Standard** - Material 3 with rounded borders, proper spacing
- **Compact** - Reduced spacing for dense layouts
- **Material** - Classic Material Design with underline inputs

You can also create fully custom styles using `FrappeFormStyle`.

## 📖 Documentation

- **[DOCUMENTATION.md](DOCUMENTATION.md)** – **Full package docs**: API calling (FrappeClient, CRUD, QueryBuilder, attachments, custom methods), form rendering (FormScreen, FrappeFormBuilder, DoctypeListScreen, DocumentListScreen, child tables, images), new APIs (requestHeaders, getMobileUuid, getMobileFormDoctypeNames, error helpers), auth, offline/sync, and quick reference.
- **[SETUP.md](SETUP.md)** - Detailed setup instructions
- **[CUSTOMIZATION.md](CUSTOMIZATION.md)** - UI customization guide
- **[TESTING.md](TESTING.md)** - Testing strategies
- **[.github/PRE_COMMIT.md](.github/PRE_COMMIT.md)** - Pre-commit hooks & CI for contributors

## 🏗️ Architecture

```
┌─────────────────────────────────────────┐
│ Your Flutter App                        │
├─────────────────────────────────────────┤
│ Option 1: Direct API (FrappeClient)    │
│ Option 2: Form Renderer (FrappeSDK)     │
│ Option 3: Custom Forms (FrappeClient)  │
└─────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────┐
│ Frappe Mobile SDK                       │
├─────────────────────────────────────────┤
│ API Layer (FrappeClient)               │
│ Services Layer (Auth, Meta, Sync)       │
│ Database Layer (SQLite)                │
│ UI Layer (Form Renderer)                │
└─────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────┐
│ Frappe Server                           │
└─────────────────────────────────────────┘
```

## 🎯 Use Cases

1. **Direct API Access** - Use `FrappeClient` for custom implementations
2. **Form Renderer** - Use `FrappeFormRenderer` for dynamic forms
3. **Hybrid Approach** - Mix API calls with form renderer
4. **Offline-First** - Use `OfflineRepository` + `SyncService`

## 🤝 Contributing

Before committing, run pre-commit checks. See **[.github/PRE_COMMIT.md](.github/PRE_COMMIT.md)** for setup.

```bash
# Flutter pre-commit (recommended)
dart run flutter_pre_commit

# Or pre-commit framework
pre-commit run --all-files
```

**GitHub Actions** run automatically on every **push** and **pull request** to `main`, `master`, and `develop`:
- **CI** – `flutter analyze`, `dart format`, `flutter test`
- **Semantic commits** – validates Conventional Commits format

## 📄 License

MIT License - see [LICENSE](LICENSE) file

**Copyright (c) 2026 Dhwani Rural Information System**

---

**Designed by:** Bhushan Barbuddhe  
**Technical Guidance:** Deepak Batra
