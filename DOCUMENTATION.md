# Frappe Mobile SDK – Documentation

Complete guide to using the Frappe Mobile SDK for **API access** and **dynamic form rendering** in Flutter. This document is intended for package consumers and release.

---

## Table of contents

1. [Overview](#1-overview)
2. [Installation & setup](#2-installation--setup)
3. [API calling](#3-api-calling)
4. [Form rendering](#4-form-rendering)
5. [New and notable APIs](#5-new-and-notable-apis)
6. [Authentication](#6-authentication)
7. [Offline & sync](#7-offline--sync)
8. [Error handling](#8-error-handling)
9. [Quick reference](#9-quick-reference)

---

## 1. Overview

The SDK provides:

- **Direct Frappe API access** – Auth, CRUD, file upload, custom method calls
- **Dynamic form rendering** – Forms generated from Frappe DocType metadata
- **Offline-first** – SQLite storage with optional bi-directional sync
- **Server requirements** – [Frappe Mobile Control](https://github.com/dhwani-ris/frappe_mobile_control) app on the Frappe server for mobile auth and app status

---

## 2. Installation & setup

### 2.1 Add dependency

```yaml
dependencies:
  frappe_mobile_sdk:
    git:
      url: https://github.com/dhwani-ris/frappe-mobile-sdk
      ref: main
```

### 2.2 Server setup

Install **Frappe Mobile Control** on your Frappe/ERPNext bench:

```bash
cd /path/to/bench
bench get-app https://github.com/dhwani-ris/frappe_mobile_control
bench install-app frappe_mobile_control
bench migrate
```

### 2.3 Initialize SDK (recommended path)

```dart
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';

final sdk = FrappeSDK(baseUrl: 'https://your-site.com');
// Basic init (no auto sync, you control when to sync)
await sdk.initialize();

// Or, automatically restore session + run initial metadata + data sync
await sdk.initialize(true); // true = autoRestoreAndSync
```

After `initialize()`, you can use `sdk.api` (FrappeClient), `sdk.auth`, `sdk.meta`, `sdk.sync`, etc.

### 2.4 API-only (no SDK)

If you only need the REST client and no form UI or offline:

```dart
final database = await AppDatabase.getInstance();
final client = FrappeClient('https://your-site.com');
final authService = AuthService();
authService.initialize('https://your-site.com', database: database);
// Then login and use client.document, client.doctype, client.attachment, client.rest.call(...)
```

---

## 3. API calling

### 3.1 FrappeClient

Obtain the client via SDK or create it directly:

```dart
FrappeClient client = sdk.api;  // after sdk.initialize()
// or
FrappeClient client = FrappeClient('https://your-site.com');
await client.initialize();  // restores session from storage if any
```

| Member | Description |
|--------|-------------|
| `client.baseUrl` | Server base URL (no trailing slash). |
| `client.rest` | Low-level `RestHelper` (GET/POST/PUT/DELETE). |
| `client.requestHeaders` | Map of auth headers (Bearer/Cookie/token). Use for authenticated image/file requests. |
| `client.doc(doctype)` | Returns a `QueryBuilder` for the doctype. |
| `client.call(method, args: {...}, httpMethod: 'POST')` | Call any Frappe server method (e.g. `frappe.client.get_list`). |

### 3.2 Document service – CRUD

```dart
// Create
Map<String, dynamic> doc = await client.document.createDocument('Customer', {
  'customer_name': 'Acme',
  'email': 'acme@example.com',
});
// doc['name'] or doc['docname'] contains the new document name.

// Update
await client.document.updateDocument('Customer', doc['name'], {
  'phone': '1234567890',
});

// Delete
await client.document.deleteDocument('Customer', doc['name']);

// Submit / Cancel (for submittable doctypes)
await client.document.submitDocument('Sales Order', 'SO-00001');
await client.document.cancelDocument('Sales Order', 'SO-00001');
```

**Create options:**

- `createDocument(doctype, data, { useFrappeClient: false })`  
  - `useFrappeClient: true` uses `frappe.client.insert` and expects `doc` in response; otherwise uses `/api/resource/$doctype`.

### 3.3 Doctype service – metadata & list

```dart
// Get DocType metadata (for form rendering or field info)
Map<String, dynamic> metaJson = await client.doctype.getDocTypeMeta('Customer');

// List documents (supports filters, order, pagination)
List<dynamic> list = await client.doctype.list(
  'Customer',
  fields: ['name', 'customer_name', 'email'],
  filters: [['Customer', 'disabled', '=', 0]],
  limitStart: 0,
  limitPageLength: 20,
  orderBy: 'modified desc',
);

// Get single document by name
Map<String, dynamic> doc = await client.doctype.getByName('Customer', 'CUST-001');
```

### 3.4 Query builder

Fluid API for list queries:

```dart
List<dynamic> todos = await client.doc('ToDo')
  .select(['name', 'description', 'status'])
  .where('status', 'Open')
  .where('owner', 'like', '%user%')
  .orderBy('creation', descending: true)
  .limit(20, start: 0)
  .get();

// Single record
Map<String, dynamic>? first = await client.doc('Customer')
  .where('name', 'CUST-001')
  .first();
```

- `where(field, operatorOrValue)` or `where(field, operator, value)`
- `filters(List<List<dynamic>>)` for raw filter arrays
- `orderBy(field, { descending: false })`
- `limit(pageLength, { start: 0 })`
- `get()` → `List<dynamic>`, `first()` → `Map<String, dynamic>?`

### 3.5 Attachment service – file upload

```dart
File file = File('/path/to/file.pdf');
Map<String, dynamic> result = await client.attachment.uploadFile(
  file,
  fileName: 'optional_name.pdf',
  doctype: 'Customer',
  docname: 'CUST-001',
  isPrivate: true,
);
// result typically contains 'file_url', 'file_name', etc.
```

### 3.6 Custom API methods

```dart
// POST (default)
dynamic result = await client.call('your_app.method_name', args: {
  'param1': 'value1',
});

// GET
dynamic result = await client.call(
  'frappe.client.get_list',
  args: { 'doctype': 'Customer', 'limit_page_length': 10 },
  httpMethod: 'GET',
);
```

---

## 4. Form rendering

### 4.1 High-level flow

1. Get **DocType metadata** (e.g. from `MetaService.getMeta(doctype)`).
2. Use **FormScreen** (full screen with AppBar save) or **FrappeFormBuilder** (embedded form).
3. Optionally use **DoctypeListScreen** and **DocumentListScreen** for list → form navigation.

### 4.2 MetaService and metadata

```dart
MetaService metaService = sdk.meta;

// Get metadata (from cache/DB or server)
DocTypeMeta meta = await metaService.getMeta('Customer');

// Force refresh from server
DocTypeMeta metaFresh = await metaService.getMeta('Customer', forceRefresh: true);

// Get list of doctypes configured for mobile (from login / sync)
List<String> doctypes = await metaService.getMobileFormDoctypeNames();

// Clear cache when leaving a screen (optional, for memory)
metaService.clearDocTypeCache('Customer');
```

`DocTypeMeta` exposes:

- `name`, `label`, `fields`, `isTable`
- `titleField` – main title in list view
- `sortField`, `sortOrder` – default list sort
- `listViewFields` – fields to show in list
- `getField(fieldname)`, `dataFields`, `layoutFields`

### 4.3 FormScreen (full-screen form)

Use for create or edit with AppBar Save and optional sync:

```dart
Navigator.push(
  context,
  MaterialPageRoute(
    builder: (context) => FormScreen(
      meta: await sdk.meta.getMeta('Customer'),
      document: existingDocument,  // null for new
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
```

| Parameter | Required | Description |
|-----------|----------|-------------|
| `meta` | Yes | DocType metadata. |
| `document` | No | Existing document (edit); `null` = new. |
| `repository` | Yes | Offline repository. |
| `syncService` | No | For push after save. |
| `linkOptionService` | No | For Link field options. |
| `metaService` | No | For child table / getMeta. |
| `api` | No | When set, save goes to server first then local. |
| `getMobileUuid` | No | When set, new docs get `mobile_uuid` on server. |
| `onSaveSuccess` | No | Callback after successful save. |

FormScreen uses **FrappeFormBuilder** internally and passes `fileUrlBase`, `imageHeaders`, `uploadFile`, `getMeta`, `fetchLinkedDocument`, `registerSubmit`.

### 4.4 FrappeFormBuilder (embedded form)

Use when you need the form inside your own layout (dialog, bottom sheet, tab):

```dart
FrappeFormBuilder(
  meta: meta,
  initialData: {'customer_name': 'Default'},
  readOnly: false,
  linkOptionService: sdk.linkOptions,
  uploadFile: (file) async {
    final res = await sdk.api.attachment.uploadFile(file);
    return res['file_url'] as String? ?? res['file_name'] as String?;
  },
  fileUrlBase: sdk.api.baseUrl,
  imageHeaders: sdk.api.requestHeaders,
  fetchLinkedDocument: (linkedDoctype, docName) async {
    try {
      return await sdk.api.doctype.getByName(linkedDoctype, docName);
    } catch (_) => null;
  },
  getMeta: (doctype) => sdk.meta.getMeta(doctype),
  registerSubmit: (submitFn) => _formSubmit = submitFn,
  onSubmit: (data) async {
    await sdk.api.document.createDocument('Customer', data);
  },
  style: DefaultFormStyle.standard,
)
```

| Parameter | Description |
|-----------|-------------|
| `meta` | DocType metadata. |
| `initialData` | Prefill values. |
| `onSubmit` | Called with form data on submit. |
| `readOnly` | Disable editing. |
| `linkOptionService` | Required for Link fields. |
| `uploadFile` | For Image/Attach: upload and return `file_url`. |
| `fileUrlBase` | Base URL for image/file preview (e.g. `api.baseUrl`). |
| `imageHeaders` | Auth headers for private files (`api.requestHeaders`). |
| `fetchLinkedDocument` | For fetch_from / link display. |
| `getMeta` | For child table (Table field) meta. |
| `registerSubmit` | Callback with form submit function (e.g. for AppBar Save). |
| `style` | `FrappeFormStyle` or `DefaultFormStyle.standard` / `.compact` / `.material`. |

### 4.5 DoctypeListScreen (list of doctypes)

Shows doctypes; optionally use doctypes from login instead of config:

```dart
// Doctypes from login (mobile_form_names)
List<String> doctypes = await sdk.meta.getMobileFormDoctypeNames();

DoctypeListScreen(
  appConfig: appConfig,
  repository: sdk.repository,
  doctypes: doctypes,  // when set, overrides appConfig.doctypes
  onDoctypeSelected: (doctype) {
    // Navigate to document list for this doctype
  },
  onNewDocument: (doctype) {
    // Navigate to new document form
  },
)
```

### 4.6 DocumentListScreen (list of documents)

List with search, sort, and pagination (uses meta’s `titleField`, `sortField`, `listViewFields`):

```dart
DocumentListScreen(
  doctype: 'Customer',
  meta: await sdk.meta.getMeta('Customer'),
  repository: sdk.repository,
  syncService: sdk.sync,
  metaService: sdk.meta,
  linkOptionService: sdk.linkOptions,
  api: sdk.api,
  getMobileUuid: () => sdk.getMobileUuid(),
  initialDocuments: null,
)
```

### 4.7 Child tables (Table field)

- Child table add/edit is shown in a **modal bottom sheet** with **Save**, **Cancel**, and **Remove** (edit only).
- Form for child rows is built by **FrappeFormBuilder** with `getMeta` for the child doctype.
- Pass **`getMeta`** on FormScreen/FrappeFormBuilder so Table fields resolve child meta.

### 4.8 Image field and private files

- Set **`fileUrlBase`** (e.g. `api.baseUrl`) and **`imageHeaders`** (e.g. `api.requestHeaders`).
- For paths like `/private/files/...` or `/files/...`, the SDK uses Frappe’s `download_file` API and sends auth via `imageHeaders` so images load in release.

### 4.9 Styling

```dart
DefaultFormStyle.standard   // Material 3, rounded
DefaultFormStyle.compact   // Dense
DefaultFormStyle.material  // Underline inputs

FrappeFormStyle(
  labelStyle: TextStyle(...),
  sectionPadding: EdgeInsets.all(20),
  fieldDecoration: (field) => InputDecoration(...),
)
```

### 4.10 Button field type

Frappe doctypes can define **Button** fields (e.g. "Fetch Data", "Submit for Approval"). The SDK renders these as tappable buttons and lets you override their behavior.

#### Default behavior

- If `field.options` contains a **server method path** (e.g. `your_app.module.method_name`), the SDK calls `api.call(method, args: {'doc': formData})` automatically.
- If `field.options` is empty, the user sees: *"Action not configured for mobile"*.
- Offline: shows *"Action unavailable offline"*.

#### Custom behavior via `onButtonPressed`

Use **OnButtonPressedCallback** (FormScreen, DocumentListScreen, `navigateToForm`) or **ButtonPressedCallback** (FrappeFormBuilder, `renderForm`) to implement custom logic (API calls, dialogs, client scripts).

**FormScreen / DocumentListScreen (recommended):**

```dart
// OnButtonPressedCallback: 3 args (field, formData, useDefault)
// Call useDefault(field, formData) to fall back to SDK default
OnButtonPressedCallback? createOnButtonPressed(FrappeClient? api) {
  if (api == null) return null;
  return (field, formData, useDefault) async {
    // Custom logic for specific button
    if (field.fieldname == 'fetch_data' && field.fieldtype == 'Button') {
      // Your API call, dialog, etc.
      await api.call('your_app.method', args: {'district': formData['land_district'], ...});
      return;
    }
    // Fall back to default (server method from field.options)
    await useDefault(field, formData);
  };
}

// Pass to FormScreen / DocumentListScreen
FormScreen(
  meta: meta,
  api: sdk.api,
  onButtonPressed: createOnButtonPressed(sdk.api),
  ...
)
```

**FrappeFormBuilder / renderForm:**

```dart
// ButtonPressedCallback: 2 args (field, formData)
// You must implement all Button behavior yourself
FrappeFormBuilder(
  meta: meta,
  onButtonPressed: (field, formData) async {
    if (field.fieldname == 'fetch_data') {
      await sdk.api.call('your_app.method', args: formData);
    }
  },
  ...
)
```

#### Callback types

| Callback | Args | Use case |
|----------|------|----------|
| `OnButtonPressedCallback` | `(field, formData, useDefault)` | FormScreen, DocumentListScreen, `navigateToForm`. Call `useDefault` for SDK default. |
| `ButtonPressedCallback` | `(field, formData)` | FrappeFormBuilder, `renderForm`. You handle all buttons. |

#### Notes

- Button fields do **not** store form values; they are action triggers only.
- `formData` is the current form state (all data fields).
- Use `field.fieldname` / `field.fieldtype` to branch by button.
- The button shows a loading indicator during async handlers.

### 4.11 Auto-select for single-option fields

For **Select** and **Link** fields, after `depends_on`, `fetch_from`, and link-filter evaluation, if the selectable option count is exactly one, the SDK automatically selects that option without user interaction.

- **Select fields** (single and multi-select): When `field.options` yields one option and there is no valid selection, the first option is auto-selected and synced to form state.
- **Link fields (direct options)**: When the options list has one item and there is no valid selection, that item is auto-selected.
- **Link fields (async dropdown)**: When options load from `LinkOptionService` (after link filters and dependent fields are resolved) and there is one option with no valid selection, it is auto-selected.

This reduces manual selection for cascading dropdowns (e.g. State Agency → District Agency → Sro) when only one valid choice exists at each step.

---

## 5. New and notable APIs

These are important for correct integration and release use.

### 5.1 Mobile UUID (new documents from app)

When creating documents from the app, the server can store a device identifier in `mobile_uuid`:

```dart
// SDK
Future<String> uuid = sdk.getMobileUuid();

// Pass to FormScreen so new docs get mobile_uuid on server
FormScreen(
  ...
  getMobileUuid: () => sdk.getMobileUuid(),
)
```

### 5.2 Request headers (private files / images)

Use for any authenticated request that is not done by the client (e.g. `Image.network` for private files):

```dart
Map<String, String> headers = client.requestHeaders;
// Contains Authorization (Bearer/Token) or Cookie as configured.
```

FormScreen passes this as `imageHeaders` to the form so image fields can load `/private/files/` URLs.

### 5.3 Doctypes from login (mobile_form_names)

Doctypes can come from the login response instead of a hard-coded list:

```dart
List<String> doctypes = await sdk.meta.getMobileFormDoctypeNames();
// Use in DoctypeListScreen(doctypes: doctypes, ...)
```

### 5.4 Metadata sync and configuration

```dart
// Prefetch metadata for mobile form doctypes (no cache fill until getMeta)
await sdk.loadMetadata();

// Sync all mobile form doctypes
await sdk.syncAll();

// Compare timestamps and sync only updated/new doctypes (e.g. after login)
await sdk.checkAndSyncDoctypes();

// Resync mobile configuration from server (mobile_auth.configuration)
await sdk.resyncMobileConfiguration();
```

### 5.5 Error message helpers

```dart
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';

// From API response body (Map or string)
String message = extractErrorMessage(responseBody);

// User-friendly short message (strips traceback, ValidationError, LinkExistsError, HTML)
String friendly = toUserFriendlyMessage(error);
```

---

## 6. Authentication

### 6.1 Login (username / password)

Uses `mobile_auth.login`; tokens are stored in DB (and optionally secure storage):

```dart
Map<String, dynamic> res = await sdk.login('username', 'password');
// res: access_token, refresh_token, user, full_name, mobile_form_names, ...
```

### 6.2 Restore session

Call after app start to restore login from stored tokens:

```dart
bool ok = await sdk.auth.restoreSession();
```

### 6.3 API key

```dart
bool ok = await sdk.loginWithApiKey(apiKey, apiSecret);
```

### 6.4 OAuth 2.0 (PKCE)

```dart
Map<String, String> prep = await sdk.prepareOAuthLogin(
  clientId: clientId,
  redirectUri: 'frappemobilesdk://oauth/callback',
  scope: 'openid all',
);
// Open prep['authorize_url'] in browser; capture code from redirect.

bool ok = await sdk.loginWithOAuth(
  code: codeFromRedirect,
  codeVerifier: prep['code_verifier']!,
  clientId: clientId,
  redirectUri: redirectUri,
);
```

Configure the same redirect URI in Frappe OAuth Client and in the app (Android intent filter / iOS URL scheme). See README for XML snippets.

### 6.5 Logout

```dart
await sdk.logout(clearDatabase: true);
```

---

## 7. Offline & sync

### 7.1 Offline repository

```dart
OfflineRepository repo = sdk.repository;

await repo.saveServerDocument(doctype: 'Customer', serverId: 'CUST-001', data: {...});
await repo.createDocument(doctype: 'Customer', data: {...});
Document? doc = await repo.getDocumentByServerId('CUST-001', 'Customer');
List<Document> docs = await repo.getDocumentsByDoctype('Customer');
```

### 7.2 Sync service

```dart
SyncService sync = sdk.sync;

// Pull from server for a doctype
SyncResult r = await sync.pullSync(doctype);

// Push local changes
SyncResult r = await sync.pushSync(doctype);
```

`SyncResult` carries counts and error messages. Optional `getMobileUuid` on SyncService can be set so new docs created during push include `mobile_uuid`.

---

## 8. Error handling

### 8.1 Exceptions

Catch these from API/form code:

| Exception | When |
|-----------|------|
| `AuthException` | 401/403. |
| `ValidationException` | 417 (validation errors; may include field details). |
| `NetworkException` | No internet / request failed. |
| `ApiException` | Other API errors (statusCode, body). |
| `FrappeException` | Base; `message`, `statusCode`. |

### 8.2 User-facing messages

```dart
try {
  await client.document.createDocument('Customer', data);
} catch (e) {
  if (e is ValidationException) {
    String msg = toUserFriendlyMessage(e.body ?? e.message);
    // Show msg to user
  } else if (e is ApiException) {
    String msg = extractErrorMessage(e.body);
    // Show msg
  }
}
```

---

## 9. Quick reference

### 9.1 SDK entry points

| What | How |
|------|-----|
| API client | `sdk.api` (FrappeClient) |
| Auth | `sdk.auth` (AuthService) |
| Meta | `sdk.meta` (MetaService) |
| Sync | `sdk.sync` (SyncService) |
| Offline | `sdk.repository` (OfflineRepository) |
| Link options | `sdk.linkOptions` (LinkOptionService) |
| Mobile UUID | `sdk.getMobileUuid()` |
| Doctypes from login | `sdk.meta.getMobileFormDoctypeNames()` |

### 9.2 Client API summary

| Service | Methods |
|---------|--------|
| `client.document` | createDocument, updateDocument, deleteDocument, submitDocument, cancelDocument |
| `client.doctype` | getDocTypeMeta, list, getByName |
| `client.attachment` | uploadFile |
| `client.rest` | get, post, put, delete |
| `client` | doc(doctype), call(method, args, httpMethod), baseUrl, requestHeaders |

### 9.3 Form / UI widgets

| Widget | Use |
|--------|-----|
| FormScreen | Full-screen form with AppBar Save, optional api/sync. |
| FrappeFormBuilder | Embedded form; use in dialogs/sheets/custom screens. |
| DoctypeListScreen | List of doctypes (optionally from login). |
| DocumentListScreen | Document list with search, sort, pagination. |
| LoginScreen | Login UI (credentials + OAuth). |
| FrappeAppGuard | App status check and force-update gate. |

### 9.4 Exports (main)

- **Core:** FrappeClient, FrappeSDK, AppDatabase
- **Models:** DocTypeMeta, DocField, Document, AppConfig
- **API:** DoctypeService, DocumentService, AttachmentService, QueryBuilder, exceptions, OAuth2Helper
- **Utils:** extractErrorMessage, toUserFriendlyMessage
- **UI:** FormScreen, FrappeFormBuilder, DoctypeListScreen, DocumentListScreen, LoginScreen, AppGuard, FrappeFormStyle, DefaultFormStyle

---

For setup details, OAuth, and Android/iOS config, see [README.md](README.md) and [SETUP.md](SETUP.md).
