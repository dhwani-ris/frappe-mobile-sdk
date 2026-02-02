# Frappe Mobile SDK

Flutter package for Frappe integration with direct API access, dynamic form rendering, and offline-first architecture.

## ✨ Features

- ✅ **Frappe API Access** - Auth, CRUD, file upload via `FrappeClient`
- ✅ **Dynamic Form Renderer** - Auto-generate forms from Frappe metadata
- ✅ **Offline-First** - Full offline capability with SQLite
- ✅ **Bi-directional Sync** - Push/pull sync with conflict resolution
- ✅ **Customizable Styling** - Default styles + full customization support

## 🚀 Quick Start

### Installation

```yaml
dependencies:
  frappe_mobile_sdk:
    git:
      url: https://github.com/dhwani-ris/frappe-mobile-sdk
      ref: main
```

### 1. API Usage (No Form Renderer)

```dart
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';

// Initialize client
final client = FrappeClient('https://your-frappe-site.com');

// Login
await client.auth.loginWithCredentials('username', 'password');

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

// Initialize SDK
final sdk = FrappeSDK(
  baseUrl: 'https://your-frappe-site.com',
  doctypes: ['Customer', 'Lead', 'Item'],
);

await sdk.initialize();
await sdk.login('username', 'password');

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
3. **App config**:
```dart
loginConfig: LoginConfig(
  enableOAuth: true,
  oauthClientId: 'your-frappe-oauth-client-id',
  oauthClientSecret: 'your-client-secret', // Required for confidential clients
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

## 📚 API Reference

### FrappeClient (Direct API)

```dart
// Authentication
client.auth.loginWithCredentials(username, password);
client.auth.setApiKey(apiKey, apiSecret);
client.auth.logout();

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
await sdk.initialize();
await sdk.login(username, password);

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
