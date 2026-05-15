# Frappe Mobile SDK

Flutter package for Frappe integration with direct API access, dynamic form rendering, and an offline‑first architecture.

---

## Table of Contents

1. [Overview](#overview)  
2. [Prerequisites](#prerequisites)  
3. [Installation](#installation)  
4. [Configuration](#configuration)  
5. [Quick Start](#quick-start)  
   - [App Status Guard (`FrappeAppGuard`)](#app-status-guard-frappeappguard)  
   - [Translations](#translations)  
6. [Core Features](#core-features)  
7. [Usage Patterns](#usage-patterns)  
   - [API Usage (no form renderer)](#api-usage-no-form-renderer)  
   - [Form Screens & Builders](#form-screens--builders)  
   - [Custom Forms Using SDK APIs](#custom-forms-using-sdk-apis)  
8. [Project Structure](#project-structure)  
9. [Setup, Customization, and Testing](#setup-customization-and-testing)  
10. [Contribution & CI](#contribution--ci)  
11. [License](#license)  
12. [Links & Further Documentation](#links--further-documentation)

---

## Overview

Frappe Mobile SDK provides:

- **Direct Frappe API access** – Auth, CRUD, file upload, custom method calls.
- **Dynamic form rendering** – Forms generated from Frappe DocType metadata.
- **Offline‑first architecture** – SQLite storage with optional bi‑directional sync.
- **Ready‑made UI screens** – Login, doctype listing, document listing, document forms, sync status.
- **Server‑driven app control** – App status check and force‑update via backend.

Use this SDK if you:

- Have an existing Frappe instance and want a Flutter mobile app on top of it.
- Need dynamic, metadata‑driven forms rather than hard‑coded UIs.
- Require offline usage with later sync to Frappe.
- Prefer using a higher‑level SDK instead of writing raw HTTP integration.

---

## Prerequisites

### Server‑Side App (Required)

To run apps built with this SDK you **must** install the companion **Frappe Mobile Control** app on your Frappe/ERPNext server. This server app is **not part of this SDK repository** – it lives in its own repo and provides:

- Mobile authentication APIs (`mobile_auth.*`).
- App status & version control (`mobile_auth.app_status`).
- Mobile app configuration and metadata endpoints.

Server repo (install & server‑side documentation):

- `https://github.com/dhwani-ris/frappe-mobile-control`

Install via bench:

```bash
cd /path/to/your/frappe-bench
bench get-app https://github.com/dhwani-ris/frappe-mobile-control
bench install-app frappe-mobile-control
bench migrate
```

All **server‑side configuration, workflows, and mobile control documentation** belong in that repository; this SDK repo focuses on the Flutter client.

---

## Installation

Add the SDK to your Flutter app’s `pubspec.yaml`:

From pub.dev:

```bash
flutter pub add frappe_mobile_sdk
```

Or:

```yaml
dependencies:
  # Pick the latest version from pub.dev
  frappe_mobile_sdk: ^<latest>
```

Package page: `https://pub.dev/packages/frappe_mobile_sdk`

From Git:

```yaml
dependencies:
  flutter:
    sdk: flutter

  frappe_mobile_sdk:
    git:
      url: https://github.com/dhwani-ris/frappe-mobile-sdk
      ref: main
```

Or use a local path during development:

```yaml
dependencies:
  frappe_mobile_sdk:
    path: ../frappe_mobile_sdk
```

Then run:

```bash
flutter pub get
```

---

## Configuration

Create a centralized config file to store your app constants (app name/version, package id, home layout, base URL, OAuth credentials, etc.). The example app uses `example/lib/config/app_config.dart` (generated from `example/lib/config/app_config.example.dart`):

```bash
cp example/lib/config/app_config.example.dart example/lib/config/app_config.dart
```

```dart
class AppConfig {
  /// App name shown in UI.
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
```

Integrate it into your app:

```dart
import 'config/app_config.dart' as config;
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';

MaterialApp(
  home: FrappeAppGuard(
    baseUrl: config.AppConfig.baseUrl,
    child: YourHomeWidget(),
  ),
);
```

> Note: your `app_config.dart` should typically be git‑ignored; only `app_config.example.dart` should be committed.

---

## Quick Start

### Basic Initialization with `FrappeSDK`

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

### App Status Guard (`FrappeAppGuard`)

Use `FrappeAppGuard` to:

- Check app status via `/api/v2/method/mobile_auth.app_status` on launch.
- Block app access if `enabled == false` or API returns 417/404.
- Show force‑update screen when package name or version mismatch.
- Redirect users to Play Store / App Store (or a custom store URL).

```dart
import 'config/app_config.dart' as config;
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';

MaterialApp(
  home: FrappeAppGuard(
    baseUrl: config.AppConfig.baseUrl,
    child: const HomeScreen(),
  ),
);
```

> Requires the `frappe_mobile_control` server app – see [Prerequisites](#prerequisites).

### Translations

The SDK can load translation dictionaries from your Frappe server and use them for **doctype labels**, **field labels**, **section/tab titles**, and validation messages.

- **Automatically**: when you call `sdk.initialize(true)` and session restore succeeds (loads English `en` dictionary once).
- **Manually**: call `sdk.translations.loadTranslations(lang)` or `sdk.translations.setLocale(lang)` to load/switch language.

Example:

```dart
// After init, optionally set language
await sdk.translations.setLocale('en');  // or 'hi', 'es', etc.

DocumentListScreen(
  doctype: doctype,
  meta: meta,
  repository: sdk.repository,
  syncService: sdk.sync,
  metaService: sdk.meta,
  permissionService: sdk.permissions,
  translate: (s) => sdk.translations.translate(s),
);
```

Server requirement for translations (handled by `frappe_mobile_control`):

- Endpoint like: `GET /api/v2/method/mobile_auth.get_translations?lang=en`  
  Response shape: `{ "data": { "lang": "en", "translations": { "Source": "Translated" } } }`.

---

## Core Features

- **Stateless Login & Session Restore**
  - Token‑based auth via `mobile_auth.login`.
  - Tokens persisted in DB; restore with `AuthService.restoreSession()` or via `FrappeSDK.initialize(true)`.
  - Automatic refresh on 401 where supported.

- **Multiple Authentication Flows**
  - Username/password.
  - Mobile OTP login (`sendLoginOtp` / `verifyLoginOtp`).
  - API key login (`loginWithApiKey`).
  - OAuth 2.0 with PKCE (`prepareOAuthLogin` / `loginWithOAuth`).

- **Direct Frappe API Access**
  - `FrappeClient` with:
    - `auth` – authentication.
    - `doctype` – metadata and listing.
    - `document` – CRUD (`createDocument`, `updateDocument`, `deleteDocument`, `submitDocument`, `cancelDocument`).
    - `attachment` – file upload.
  - `QueryBuilder` via `client.doc('ToDo').where(...).orderBy(...).limit(...).get()`.
  - Arbitrary method calls via `client.call(method, args: {...})`.

- **Dynamic Form Renderer**
  - Auto‑generate forms from Frappe metadata:
    - Uses `DocTypeMeta`, `DocField`, `Document`, `WorkflowTransition`.
  - Widgets:
    - `DoctypeListScreen`, `DocumentListScreen`, `FormScreen`, `FrappeFormBuilder`.
  - Field types:
    - Text/data, numeric, date/time, check, link, child table, attachment, phone, password, rating, image, etc.
  - Button field support via `OnButtonPressedCallback` with default or custom server calls.

- **Offline‑First Architecture**
  - SQLite (`AppDatabase`) for:
    - Doctype metadata, documents, auth tokens, permissions, link options.
  - `OfflineRepository`:
    - Local CRUD operations on docs.
    - Tracks dirty (unsynced) documents (`getDirtyDocuments`).
  - `SyncService`:
    - `isOnline()`, `pullSync(doctype: ...)`.
    - Integrated into example flows to sync before showing lists.

- **Workflows**
  - Workflow detection via metadata (`DocTypeMeta.hasWorkflow`, `workflowStateField`).
  - `WorkflowService` for:
    - Fetching transitions (`get_transitions`).
    - Applying actions (`apply_workflow`) and updating local data.
  - `FormScreen`:
    - Frappe‑like AppBar:
      - Unsaved changes → shows Save (and Delete if allowed).
      - Clean form + workflow → shows workflow actions instead of Save.
      - New document → Save only; workflow after first save.
    - Submitted documents (`docstatus == 1`) are read‑only.
  - Details: `doc/WORKFLOWS.md`.

- **Styling & Customization**
  - Predefined styles: `DefaultFormStyle.standard`, `DefaultFormStyle.compact`, `DefaultFormStyle.material`.
  - Fully custom styles via `FrappeFormStyle`.
  - Extensibility points:
    - Custom field factory.
    - Custom field widgets.
  - See `CUSTOMIZATION.md` for detailed guidance.

- **Utilities & Error Handling**
  - Exceptions:
    - `FrappeException`, `AuthException`, `ApiException`, `NetworkException`, `ValidationException`.
  - Helpers:
    - `extractErrorMessage(error)`, `toUserFriendlyMessage(error)` for mapping raw errors to readable text.
  - `ApiTracer` for debugging API calls.

---

## Usage Patterns

### API Usage (no form renderer)

```dart
import 'dart:io';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';

// Initialize database (required for stateless login)
final database = await AppDatabase.getInstance();

// Auth service + client
final authService = AuthService();
authService.initialize('https://your-frappe-site.com', database: database);

// Stateless login via mobile_auth.login
final loginResponse = await authService.login('username', 'password');

// Restore session on app launch
final isAuthenticated = await authService.restoreSession();

// Create FrappeClient
final client = FrappeClient('https://your-frappe-site.com');
await client.initialize();

// CRUD
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

// File upload
final file = File('/path/to/file.pdf');
final uploaded = await client.attachment.uploadFile(file);

// Query builder
final todos = await client
    .doc('ToDo')
    .where('status', 'Open')
    .orderBy('creation', descending: true)
    .limit(10)
    .get();
```

### Form Screens & Builders

Use ready‑made screens when you want a full mobile experience quickly (the example app demonstrates this pattern).

```dart
// After SDK initialization and successful login

// List mobile doctypes
final doctypes = await sdk.meta.getMobileFormDoctypeNames();

Navigator.push(
  context,
  MaterialPageRoute(
    builder: (context) => DoctypeListScreen(
      appConfig: AppConfig(
        baseUrl: 'https://your-frappe-site.com',
        doctypes: doctypes,
        loginConfig: LoginConfig(
          enableMobileLogin: true,
          enablePasswordLogin: true,
          enableOAuth: true,
          oauthClientId: 'your_oauth_client_id',
          oauthClientSecret: 'your_oauth_client_secret',
        ),
      ),
      repository: sdk.repository,
      doctypes: doctypes,
      onDoctypeSelected: (doctype) async {
        final meta = await sdk.meta.getMeta(doctype);

        if (await sdk.sync.isOnline()) {
          await sdk.sync.pullSync(doctype: doctype);
        }

        final docs = await sdk.repository.getDocumentsByDoctype(doctype);

        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => DocumentListScreen(
              doctype: doctype,
              meta: meta,
              repository: sdk.repository,
              syncService: sdk.sync,
              metaService: sdk.meta,
              linkOptionService: sdk.linkOptions,
              api: sdk.api,
              getMobileUuid: () => sdk.getMobileUuid(),
              initialDocuments: docs,
              userRoles: sdk.roles,
              permissionService: sdk.permissions,
              translate: (s) => sdk.translations.translate(s),
            ),
          ),
        );
      },
      onNewDocument: (doctype) async {
        final meta = await sdk.meta.getMeta(doctype);
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => FormScreen(
              meta: meta,
              repository: sdk.repository,
              syncService: sdk.sync,
              linkOptionService: sdk.linkOptions,
              metaService: sdk.meta,
              api: sdk.api,
              getMobileUuid: () => sdk.getMobileUuid(),
              onSaveSuccess: () => Navigator.pop(context),
            ),
          ),
        );
      },
    ),
  ),
);
```

**Button field handling**:

```dart
OnButtonPressedCallback? createHandler(FrappeClient api) {
  return (field, formData, useDefault) async {
    if (field.fieldname == 'fetch_data') {
      await api.call('your_app.method', args: formData);
      return;
    }
    await useDefault(field, formData); // SDK default for other buttons
  };
}

FormScreen(
  meta: meta,
  repository: sdk.repository,
  syncService: sdk.sync,
  linkOptionService: sdk.linkOptions,
  api: sdk.api,
  onButtonPressed: createHandler(sdk.api),
);
```

See `DOCUMENTATION.md` (§ Button field type) for full details.

### Custom Forms Using SDK APIs

```dart
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';

class CustomCustomerForm extends StatefulWidget {
  const CustomCustomerForm({super.key, required this.client});
  final FrappeClient client;

  @override
  State<CustomCustomerForm> createState() => _CustomCustomerFormState();
}

class _CustomCustomerFormState extends State<CustomCustomerForm> {
  final Map<String, dynamic> _data = {};

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TextField(
          decoration: const InputDecoration(labelText: 'Customer Name'),
          onChanged: (value) => _data['customer_name'] = value,
        ),
        ElevatedButton(
          onPressed: () async {
            await widget.client.document.createDocument('Customer', _data);
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
```

---

## Project Structure

High‑level layout:

```text
lib/
├── frappe_mobile_sdk.dart      # Public SDK barrel file
└── src/
    ├── api/                    # Frappe HTTP client & services
    ├── constants/              # Field type & OAuth constants
    ├── database/               # SQLite DB: DAOs + entities
    ├── models/                 # AppConfig, DocTypeMeta, DocField, Document, etc.
    ├── sdk/                    # High-level FrappeSDK
    ├── services/               # Auth, meta, sync, permissions, translations, workflows, etc.
    ├── ui/                     # Ready-made screens & widgets
    └── utils/                  # Tracing & misc utilities
```

The `example/` directory contains a complete Flutter app wiring these pieces together.

---

## Setup, Customization, and Testing

This repository includes focused documents (under `doc/` unless noted):

- `doc/SETUP.md` – SDK setup, app config, Android/iOS configuration.
  - Includes a dedicated "Social Login (OAuth) Configuration" guide (Frappe server + mobile deep-link setup).
- `doc/CUSTOMIZATION.md` – UI customization:
  - `FrappeFormStyle`, custom field factories, custom field widgets.
- `doc/FIELD_TYPES.md` – Supported field types, SearchableSelect, Link, Table MultiSelect, Geolocation, DependsOn evaluator.
- `doc/LINK_FILTER_BUILDER.md` – Runtime override of Link / Table MultiSelect filters using `LinkFilterBuilder` (PR #35). Covers API, wiring, precedence, and recipes.
- `doc/FIELD_CHANGE_HANDLER.md` – `onFieldChange` / `FieldChangeHandler` hook for derived-field patches, snapshot-isolation guarantees, and per-doctype resolution via `MobileHomeScreen.getFieldChangeHandler` (PR #35).
- `doc/TESTING.md` – Testing strategies:
  - Running the example app.
  - Using local path vs Git dependency.
  - Automated and manual tests.
- `doc/QUICK_TEST.md` – Short, practical instructions to quickly validate the SDK.
- `doc/WORKFLOWS.md` – Detailed workflow behavior in the mobile SDK.

For a full conceptual/API guide (installation, API calling, forms, auth, offline & sync, error handling, translations), see **`doc/DOCUMENTATION.md`**.

---

## Links & Further Documentation

- SDK repo: `https://github.com/dhwani-ris/frappe-mobile-sdk`
- Server companion app (required): `https://github.com/dhwani-ris/frappe-mobile-control`

In‑repo documentation:

- `doc/DOCUMENTATION.md` – Full SDK documentation.
- `doc/SETUP.md` – Environment and platform setup.
- `doc/CUSTOMIZATION.md` – UI customization guide.
- `doc/FIELD_TYPES.md` – Field type reference.
- `doc/LINK_FILTER_BUILDER.md` – Runtime Link / Table MultiSelect filter overrides.
- `doc/FIELD_CHANGE_HANDLER.md` – Field-edit hook with patch-map contract.
- `doc/TESTING.md` – Testing and verification guide.
- `doc/QUICK_TEST.md` – Quick validation steps.
- `doc/WORKFLOWS.md` – Workflow behavior.
- `.github/PRE_COMMIT.md` – Pre‑commit and CI details.

# Frappe Mobile SDK

Flutter package for Frappe integration with direct API access, dynamic form rendering, and offline-first architecture.

## Features

- **Stateless Login** - Token-based authentication via `mobile_auth.login` API
- **Keep User Logged In** - Tokens persist in database, automatic session restore
- **Auto Token Refresh** - Automatic token refresh on expiry (401 errors)
- **Frappe API Access** - Auth, CRUD, file upload via `FrappeClient`
- **Dynamic Form Renderer** - Auto-generate forms from Frappe metadata
- **Offline-First** - Full offline capability with SQLite
- **Bi-directional Sync** - Push/pull sync with conflict resolution
- **Customizable Styling** - Default styles + full customization support
- **Translations** - Load Frappe translations by language; map to field labels and doctype labels in forms and lists
- **Workflows** - Show workflow state and transition actions on forms when the DocType has a workflow (see [Workflows](doc/WORKFLOWS.md))

## Prerequisites

### Server-Side Setup (Required)

Before using this SDK, you need to install the **Frappe Mobile Control** app on your Frappe/ERPNext server. This app provides mobile-specific APIs including app status checking, version control, and mobile app configuration.

**Installation:**

1. **Install via Git** (recommended):
   ```bash
   cd /path/to/your/frappe-bench
   bench get-app https://github.com/dhwani-ris/frappe-mobile-control
   bench install-app frappe-mobile-control
   bench migrate
   ```

2. **Or install manually**:
   - Clone the repository: `git clone https://github.com/dhwani-ris/frappe-mobile-control`
   - Follow the installation instructions in the repository

**Repository**: [https://github.com/dhwani-ris/frappe-mobile-control](https://github.com/dhwani-ris/frappe-mobile-control)

## Quick Start

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
   cp example/lib/config/app_config.example.dart example/lib/config/app_config.dart
   ```

2. **Update config values** in `example/lib/config/app_config.dart`:
   ```dart
   class AppConfig {
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
       baseUrl: config.AppConfig.baseUrl,
       child: YourHomeWidget(),
     ),
   )
   
   // Use in AppConfig
   AppConfig(
     baseUrl: config.AppConfig.baseUrl,
     doctypes: config.AppConfig.doctypes,
     loginConfig: LoginConfig(
       enableOAuth: true,
       oauthClientId: config.AppConfig.oauthClientId,
       oauthClientSecret: config.AppConfig.oauthClientSecret,
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

**Note**: Requires [Frappe Mobile Control](https://github.com/dhwani-ris/frappe_mobile_control) app installed on your Frappe server (see [Prerequisites](#prerequisites-1) above).

**Required**: Wrap your app's root widget with `FrappeAppGuard`:
```dart
MaterialApp(
  home: FrappeAppGuard(
    baseUrl: config.AppConfig.baseUrl,
    child: YourHomeWidget(),
  ),
)
```

### Translations

The SDK can load translation dictionaries from your Frappe server and use them for **doctype labels**, **field labels**, **section/tab titles**, and validation messages in forms and lists.

**When translations are synced**

- **Automatically:** Only when you call `sdk.initialize(true)` (auto restore + sync) and the user is already logged in (session restore succeeds). In that case the SDK calls the translations API once and loads the **English** (`en`) dictionary. No other language is loaded automatically.
- **Manually:** Call `sdk.translations.loadTranslations(lang)` or `sdk.translations.setLocale(lang)` to load or switch language (e.g. after login or when the user changes language in settings).

**Server requirement**

Your backend must expose an API that returns the translation map for a language (e.g. `GET /api/v2/method/mobile_auth.get_translations?lang=en`). Response shape: `{ "data": { "lang": "en", "translations": { "Source string": "Translated string" } } }`.

**Using translations in the UI**

Pass a `translate` callback into the list and form screens so labels use the cached dictionary:

```dart
// After init, optionally set language (e.g. from user preference or device locale)
await sdk.translations.setLocale('en');  // or 'hi', 'es', etc.

// When opening DocumentListScreen and FormScreen, pass translate:
DocumentListScreen(
  doctype: doctype,
  meta: meta,
  repository: repository,
  syncService: syncService,
  metaService: metaService,
  permissionService: sdk.permissions,
  translate: (s) => sdk.translations.translate(s),
  // ...
);

// FormScreen receives translate from DocumentListScreen when opening a document.
// Or pass it explicitly: FormScreen(..., translate: (s) => sdk.translations.translate(s));
```

**What gets translated**

- **DocumentListScreen:** App bar title (doctype label), sort menu field labels.
- **FormScreen:** App bar title (doctype label).
- **FrappeFormBuilder:** Field labels, placeholders, descriptions, section titles, tab labels (and child table forms).
- **BaseField:** Label above the widget, description text, and validation message (“X is required”).

**API summary**

| Member | Description |
|--------|-------------|
| `sdk.translations` | TranslationService (after `initialize()`). |
| `loadTranslations(lang)` | Fetches and caches the translation map for `lang`. |
| `setLocale(lang)` | Sets current language and loads it if not cached. |
| `translate(source, [args])` | Returns translated string for current language; replaces `{0}`, `{1}` with `args`. |
| `currentLang` | Current language code (default `en`). |

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

### Button field type

Frappe Button fields (e.g. "Fetch Data") can call server methods or custom logic. Pass `onButtonPressed` to FormScreen or DocumentListScreen:

```dart
OnButtonPressedCallback? createHandler(FrappeClient? api) {
  if (api == null) return null;
  return (field, formData, useDefault) async {
    if (field.fieldname == 'fetch_data') {
      await api.call('your_app.method', args: formData);
      return;
    }
    await useDefault(field, formData); // SDK default for other buttons
  };
}

FormScreen(
  meta: meta,
  api: sdk.api,
  onButtonPressed: createHandler(sdk.api),
  ...
)
```

See **[DOCUMENTATION.md § 4.10 Button field type](DOCUMENTATION.md#410-button-field-type)** for full details and callback types.

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
  oauthClientId: config.AppConfig.oauthClientId,
  oauthClientSecret: config.AppConfig.oauthClientSecret, // Required for confidential clients
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

### One-tap social provider UX (Google/Microsoft/etc.)

Enable provider-direct buttons in `LoginScreen`:

- Set `enableSocialLogin: true` in `LoginConfig`.
- Keep `autoDiscoverSocialProviders: true` to fetch providers from backend automatically.
- Keep `enableOAuth: true` (social uses OAuth internally).
- Implement backend methods in your mobile control app:
  - `mobile_auth.get_social_login_providers` (reads enabled providers from Social Login Key)
  - `mobile_auth.get_social_authorize_url` (returns provider-direct authorize URL)

When available, users can tap `Continue with Google` directly from the app, instead of first opening a generic Frappe OAuth page and then choosing the provider.

## Stateless Login & Keep User Logged In

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
- **Login**: Tokens stored in database automatically
- **App restart**: `restoreSession()` finds tokens → user stays logged in
- **Token expiry**: On 401 error, automatically refreshes using `refresh_token`
- **Logout**: Clears tokens from database → user must login again

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

**Layout:** When multiple methods are enabled, the screen shows: Password (if enabled) → **OR** → Login with mobile → Login with OAuth. If password login is disabled, the mobile OTP section is expanded by default. Opening **Login with mobile** hides the username/password box (toggle); **Back to password** shows it again. Pass `passwordLogin`, `sendLoginOtp`, and `verifyLoginOtp` from the SDK (e.g. `(u,p) => sdk.login(u,p)`) so permissions and locale are applied.

**Style:** Pass optional `style: LoginScreenStyle(...)` to customize title, icon, input decorations, button styles, and padding. Full property list: [DOCUMENTATION.md §6.7](DOCUMENTATION.md#67-login-screen-layout-and-style).

**OAuth and 401:** If you get *401 Invalid authentication token* on `mobile_auth.configuration` after OAuth login, the server may only accept tokens from `mobile_auth.login`. Ensure the backend accepts the OAuth-issued Bearer token for v2 methods (see [DOCUMENTATION.md §6.6](DOCUMENTATION.md#66-oauth-token-and-v2-apis-401-invalid-authentication-token)).

## API Reference

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

## Styling Options

The package provides three default styles:

- **Standard** - Material 3 with rounded borders, proper spacing
- **Compact** - Reduced spacing for dense layouts
- **Material** - Classic Material Design with underline inputs

You can also create fully custom styles using `FrappeFormStyle`.

## Documentation

- **[DOCUMENTATION.md](DOCUMENTATION.md)** – **Full package docs**: API calling (FrappeClient, CRUD, QueryBuilder, attachments, custom methods), form rendering (FormScreen, FrappeFormBuilder, DoctypeListScreen, DocumentListScreen, child tables, images, **Button field type**), new APIs (requestHeaders, getMobileUuid, getMobileFormDoctypeNames, error helpers), auth, offline/sync, and quick reference.
- **[SETUP.md](SETUP.md)** - Detailed setup instructions
- **[CUSTOMIZATION.md](CUSTOMIZATION.md)** - UI customization guide
- **[TESTING.md](TESTING.md)** - Testing strategies
- **[.github/PRE_COMMIT.md](.github/PRE_COMMIT.md)** - Pre-commit hooks & CI for contributors

## Architecture

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

## Use Cases

1. **Direct API Access** - Use `FrappeClient` for custom implementations
2. **Form Renderer** - Use `FrappeFormRenderer` for dynamic forms
3. **Hybrid Approach** - Mix API calls with form renderer
4. **Offline-First** - Use `OfflineRepository` + `SyncService`

## Contributing

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

## License

MIT License - see [LICENSE](LICENSE) file

**Copyright (c) 2026 Dhwani Rural Information System**

<p align="center">
  <img src="logo.png" alt="Maintainers logo" width="120" />
</p>