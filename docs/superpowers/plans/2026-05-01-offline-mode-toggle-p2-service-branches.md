# Offline Mode Toggle — P2: SDK service branches + boot wiring

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the persisted `offline_enabled` flag actually gate the SDK's read/write paths. When `enabled = false`, SQLite document tables are not created, the closure pull is skipped, all REST calls go direct, no outbox/link_options writes occur. P2 includes a **conservative residue guard** so it ships safely even before P3's transition handler exists: if residue is detected and the persisted flag is `false`, the SDK boots in offline mode anyway and logs a warning. P3 replaces this guard with the real drain/wipe flow.

**Architecture:** A single `OfflineMode` value (passed by constructor) flows into `OfflineRepository`, `SyncService`, `LinkOptionService`, and `UnifiedResolver`. Each service short-circuits one public entry. `FrappeSDK.initialize()` reads the persisted mode + residue, computes a session-bound mode via `_resolveBootMode`, constructs services with that value, and gates `_initialMetaAndDataSync`'s closure pull on the same flag.

**Tech Stack:** Dart (sqflite, http, flutter_test).

**Spec reference:** `docs/superpowers/specs/2026-05-01-offline-mode-toggle-design.md` §4.3, §4.4, §5, §10.4(b).

**Prerequisite:** P1 merged (server contract + persistence layer present).

**User-driven commits:** no commits scripted; commit when explicitly asked.

---

## File structure

| Path | Action | Responsibility |
|---|---|---|
| `frappe-mobile-sdk/lib/src/query/unified_resolver.dart` | modify | Add constructor param `offlineMode`; `_onlinePassthrough` short-circuit at top of `resolve()` |
| `frappe-mobile-sdk/lib/src/services/offline_repository.dart` | modify | Add constructor param `offlineMode`; online passthrough for create/update/delete; `getDirtyDocuments` returns `[]` |
| `frappe-mobile-sdk/lib/src/services/sync_service.dart` | modify | Add constructor param `offlineMode`; short-circuit every public method |
| `frappe-mobile-sdk/lib/src/services/link_option_service.dart` | modify | Add constructor param `offlineMode`; online passthrough |
| `frappe-mobile-sdk/lib/src/sdk/frappe_sdk.dart` | modify | Add `_offlineMode` field, `_resolveBootMode`, residue guard; pass into service constructors; gate closure pull in `_initialMetaAndDataSync`; update `forTesting` constructor |
| `frappe-mobile-sdk/test/query/unified_resolver_online_test.dart` | create | Online-mode passthrough tests |
| `frappe-mobile-sdk/test/services/offline_repository_online_test.dart` | create | Online-mode CRUD tests |
| `frappe-mobile-sdk/test/services/sync_service_online_test.dart` | create | No-op tests |
| `frappe-mobile-sdk/test/services/link_option_service_online_test.dart` | create | Online-mode passthrough tests |
| `frappe-mobile-sdk/test/sdk/frappe_sdk_boot_mode_test.dart` | create | `_resolveBootMode` + residue guard tests |

---

## Task 1: Add `offlineMode` parameter to `UnifiedResolver`

**Files:**
- Modify: `frappe-mobile-sdk/lib/src/query/unified_resolver.dart`

- [ ] **Step 1.1: Add field and constructor param**

Add to imports:
```dart
import '../models/offline_mode.dart';
import '../api/client.dart';
```

Add a field and update the constructor:

```dart
class UnifiedResolver {
  final Database db;
  final DoctypeMetaDao metaDao;
  final IsOnlineFn isOnline;
  final BackgroundFetcher backgroundFetch;
  final MetaResolverFn metaResolver;
  final OfflineMode offlineMode;
  final FrappeClient client;

  final Map<String, Future<void>> _inflightBg = {};

  UnifiedResolver({
    required this.db,
    required this.metaDao,
    required this.isOnline,
    required this.backgroundFetch,
    required this.metaResolver,
    required this.offlineMode,
    required this.client,
  });
  ...
}
```

- [ ] **Step 1.2: Add `_onlinePassthrough` and short-circuit `resolve`**

At the top of `resolve()`:

```dart
Future<QueryResult<Map<String, Object?>>> resolve({
  required String doctype,
  List<List> filters = const [],
  List<List> orFilters = const [],
  String? orderBy,
  int page = 0,
  int pageSize = 50,
  bool includeFailed = false,
}) async {
  if (!offlineMode.enabled) {
    return _onlinePassthrough(
      doctype: doctype,
      filters: filters,
      orFilters: orFilters,
      orderBy: orderBy,
      page: page,
      pageSize: pageSize,
    );
  }
  // ... existing DB-first body unchanged
}
```

Add the new method below `resolve`:

```dart
Future<QueryResult<Map<String, Object?>>> _onlinePassthrough({
  required String doctype,
  required List<List> filters,
  required List<List> orFilters,
  required String? orderBy,
  required int page,
  required int pageSize,
}) async {
  final response = await client.document.getDocList(
    doctype,
    filters: filters,
    orFilters: orFilters.isEmpty ? null : orFilters,
    orderBy: orderBy,
    limitStart: page * pageSize,
    limitPageLength: pageSize,
  );

  final raw = response is List
      ? response.cast<Map<String, dynamic>>()
      : <Map<String, dynamic>>[];
  final rows = raw
      .map((r) => Map<String, Object?>.from(r))
      .toList();

  return QueryResult<Map<String, Object?>>(
    rows: rows,
    hasMore: rows.length == pageSize,
    returnedCount: rows.length,
    originBreakdown: rows.isEmpty
        ? const {}
        : {RowOrigin.server: rows.length},
  );
}
```

If `client.document.getDocList(...)` does not match the existing `FrappeClient` API exactly, adjust to the actual method signature. The principle: a parameterized REST list call with filters, orFilters, orderBy, page-style pagination.

- [ ] **Step 1.3: Update existing tests for the new constructor**

Existing tests of `UnifiedResolver` need `offlineMode: OfflineMode(enabled: true, isPersisted: true)` and `client:` passed in. Find and update them with a quick grep:

```
cd /home/omprakash/Desktop/snf/frappe-mobile-sdk && grep -rn "UnifiedResolver(" lib/ test/
```

For every constructor call site, add the two new required parameters. Test sites typically pass a fake/no-op client and `OfflineMode(enabled: true, isPersisted: true)` to keep existing offline-mode tests green.

- [ ] **Step 1.4: Run analyzer**

```
flutter analyze
```
Expected: no new errors.

---

## Task 2: Online-mode test for `UnifiedResolver`

**Files:**
- Create: `frappe-mobile-sdk/test/query/unified_resolver_online_test.dart`

- [ ] **Step 2.1: Write the failing test**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/database/daos/doctype_meta_dao.dart';
import 'package:frappe_mobile_sdk/src/models/offline_mode.dart';
import 'package:frappe_mobile_sdk/src/query/unified_resolver.dart';
import 'package:frappe_mobile_sdk/src/query/query_result.dart';

import '../helpers/fake_frappe_client.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('online mode returns server rows without touching DB', () async {
    final db = await AppDatabase.inMemoryDatabase();
    final fakeClient = FakeFrappeClient()
      ..stubGetDocList('Customer', [
        {'name': 'CUST-1', 'customer_name': 'Acme'},
        {'name': 'CUST-2', 'customer_name': 'Beta'},
      ]);

    final resolver = UnifiedResolver(
      db: db.rawDatabase,
      metaDao: DoctypeMetaDao(db.rawDatabase),
      isOnline: () => true,
      backgroundFetch: (_, __) async {},
      metaResolver: (_) async => throw StateError('meta not needed online'),
      offlineMode: const OfflineMode(enabled: false, isPersisted: true),
      client: fakeClient,
    );

    final result = await resolver.resolve(doctype: 'Customer');

    expect(result.rows.length, 2);
    expect(result.rows.first['name'], 'CUST-1');
    expect(result.originBreakdown[RowOrigin.server], 2);
    expect(fakeClient.getDocListCalls.single.doctype, 'Customer');
    await db.close();
  });
}
```

- [ ] **Step 2.2: Create the test helper**

Path: `frappe-mobile-sdk/test/helpers/fake_frappe_client.dart`

This file is a shared test seam reused by Tasks 2, 3, 5. Implement a minimal subset of `FrappeClient` covering only the methods exercised in P2 tests. Use the `FrappeClient` API as the contract; if the SDK's client uses a different shape, adjust.

```dart
import 'package:frappe_mobile_sdk/src/api/client.dart';

class _GetDocListCall {
  final String doctype;
  final List<List>? filters;
  final List<List>? orFilters;
  final String? orderBy;
  final int? limitStart;
  final int? limitPageLength;
  _GetDocListCall(this.doctype, this.filters, this.orFilters, this.orderBy,
      this.limitStart, this.limitPageLength);
}

class FakeFrappeClient implements FrappeClient {
  final Map<String, List<Map<String, dynamic>>> _docListStubs = {};
  final List<_GetDocListCall> getDocListCalls = [];
  final List<Map<String, dynamic>> createCalls = [];
  final List<Map<String, dynamic>> updateCalls = [];
  final List<Map<String, dynamic>> deleteCalls = [];

  void stubGetDocList(String doctype, List<Map<String, dynamic>> rows) {
    _docListStubs[doctype] = rows;
  }

  @override
  noSuchMethod(Invocation i) {
    if (i.memberName == #document) return _DocumentApi(this);
    return super.noSuchMethod(i);
  }
}

class _DocumentApi {
  final FakeFrappeClient _client;
  _DocumentApi(this._client);

  Future<dynamic> getDocList(
    String doctype, {
    List<List>? filters,
    List<List>? orFilters,
    String? orderBy,
    int? limitStart,
    int? limitPageLength,
  }) async {
    _client.getDocListCalls.add(_GetDocListCall(
      doctype, filters, orFilters, orderBy, limitStart, limitPageLength,
    ));
    return _client._docListStubs[doctype] ?? const [];
  }

  Future<dynamic> createDocument(String doctype, Map<String, dynamic> data) async {
    _client.createCalls.add({'doctype': doctype, ...data});
    return {...data, 'name': 'NEW-${_client.createCalls.length}'};
  }

  Future<dynamic> updateDocument(String doctype, String name, Map<String, dynamic> data) async {
    _client.updateCalls.add({'doctype': doctype, 'name': name, ...data});
    return {...data, 'name': name};
  }

  Future<dynamic> deleteDocument(String doctype, String name) async {
    _client.deleteCalls.add({'doctype': doctype, 'name': name});
    return null;
  }
}
```

If the SDK's `FrappeClient` does not expose `document.getDocList/createDocument/updateDocument/deleteDocument` with these exact names, replace with the actual method names found via:

```
grep -rn "createDocument\|getDocList\|updateDocument\|deleteDocument" /home/omprakash/Desktop/snf/frappe-mobile-sdk/lib/src/api/
```

- [ ] **Step 2.3: Run and verify pass**

```
flutter test test/query/unified_resolver_online_test.dart
```
Expected: passes.

---

## Task 3: `OfflineRepository` online-mode passthrough

**Files:**
- Modify: `frappe-mobile-sdk/lib/src/services/offline_repository.dart`
- Create: `frappe-mobile-sdk/test/services/offline_repository_online_test.dart`

- [ ] **Step 3.1: Read current `OfflineRepository`**

Use the Read tool. Confirm the public API: `create`, `update`, `delete`, `getDirtyDocuments`, `query`, `get`, `markSynced`, `markFailed`. Confirm constructor signature.

- [ ] **Step 3.2: Add `offlineMode` parameter and `client` injection**

Add fields and constructor parameter:

```dart
final OfflineMode offlineMode;
final FrappeClient client;

OfflineRepository(
  AppDatabase database, {
  required LocalWriter localWriter,
  required this.offlineMode,
  required this.client,
}) : ...;
```

- [ ] **Step 3.3: Branch the write methods**

For each of `create`, `update`, `delete`:

```dart
Future<Document> create(String doctype, Map<String, dynamic> data) async {
  if (!offlineMode.enabled) {
    final response = await client.document.createDocument(doctype, data);
    return Document.fromJson(response is Map<String, dynamic> ? response : data);
  }
  // ... existing offline-write body unchanged
}
```

Adapt the response mapping to whatever the existing `Document` model expects. If `createDocument` returns the server's view of the row, mapping should be straightforward.

- [ ] **Step 3.4: Branch `getDirtyDocuments`**

```dart
Future<List<Document>> getDirtyDocuments() async {
  if (!offlineMode.enabled) return const [];
  // ... existing offline body
}
```

- [ ] **Step 3.5: Branch `markSynced`/`markFailed`/etc.**

For each helper that mutates local sync state, add `if (!offlineMode.enabled) return;` at the top.

- [ ] **Step 3.6: Write the failing online-mode test**

Path: `frappe-mobile-sdk/test/services/offline_repository_online_test.dart`

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/models/offline_mode.dart';
import 'package:frappe_mobile_sdk/src/services/local_writer.dart';
import 'package:frappe_mobile_sdk/src/services/offline_repository.dart';

import '../helpers/fake_frappe_client.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('create routes to REST and skips outbox in online mode', () async {
    final db = await AppDatabase.inMemoryDatabase();
    final client = FakeFrappeClient();
    final repo = OfflineRepository(
      db,
      localWriter: LocalWriter(db.rawDatabase, (_) async => throw 'meta not used'),
      offlineMode: const OfflineMode(enabled: false, isPersisted: true),
      client: client,
    );

    await repo.create('Customer', {'customer_name': 'Acme'});

    expect(client.createCalls.length, 1);
    expect(client.createCalls.single['customer_name'], 'Acme');
    final outboxRows = await db.rawDatabase.rawQuery('SELECT * FROM outbox');
    expect(outboxRows, isEmpty);
    await db.close();
  });

  test('getDirtyDocuments returns empty in online mode', () async {
    final db = await AppDatabase.inMemoryDatabase();
    final repo = OfflineRepository(
      db,
      localWriter: LocalWriter(db.rawDatabase, (_) async => throw 'meta not used'),
      offlineMode: const OfflineMode(enabled: false, isPersisted: true),
      client: FakeFrappeClient(),
    );

    final dirty = await repo.getDirtyDocuments();
    expect(dirty, isEmpty);
    await db.close();
  });
}
```

- [ ] **Step 3.7: Run and verify pass**

```
flutter test test/services/offline_repository_online_test.dart
```
Expected: passes.

---

## Task 4: `SyncService` no-op when offline mode is off

**Files:**
- Modify: `frappe-mobile-sdk/lib/src/services/sync_service.dart`
- Create: `frappe-mobile-sdk/test/services/sync_service_online_test.dart`

- [ ] **Step 4.1: Add constructor parameter**

```dart
final OfflineMode offlineMode;

SyncService(
  this._client,
  this._repository,
  this._database, {
  required FutureOr<String> Function() getMobileUuid,
  required this.offlineMode,
}) : _getMobileUuid = getMobileUuid;
```

- [ ] **Step 4.2: Short-circuit every public method**

For each public async method (`pullSync`, `pushSync`, `flushOutbox`, `flushPendingAttachments`, …) add at the very top:

```dart
if (!offlineMode.enabled) return SyncResult.empty();
```

Use `Future<void>` returns where the method returns void; `return;` for those. For methods returning `SyncResult` or similar, return a sentinel "did nothing" value. If `SyncResult.empty()` does not exist, add a static const factory on `SyncResult` returning a result with zero records affected.

- [ ] **Step 4.3: Write the failing test**

Path: `frappe-mobile-sdk/test/services/sync_service_online_test.dart`

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/models/offline_mode.dart';
import 'package:frappe_mobile_sdk/src/services/local_writer.dart';
import 'package:frappe_mobile_sdk/src/services/offline_repository.dart';
import 'package:frappe_mobile_sdk/src/services/sync_service.dart';

import '../helpers/fake_frappe_client.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('pullSync is a no-op in online mode', () async {
    final db = await AppDatabase.inMemoryDatabase();
    final client = FakeFrappeClient();
    final repo = OfflineRepository(
      db,
      localWriter: LocalWriter(db.rawDatabase, (_) async => throw 'meta'),
      offlineMode: const OfflineMode(enabled: false, isPersisted: true),
      client: client,
    );
    final sync = SyncService(
      client, repo, db,
      getMobileUuid: () async => 'test-uuid',
      offlineMode: const OfflineMode(enabled: false, isPersisted: true),
    );

    await sync.pullSync(doctype: 'Customer');
    expect(client.getDocListCalls, isEmpty);
    await db.close();
  });
}
```

- [ ] **Step 4.4: Run and verify pass**

```
flutter test test/services/sync_service_online_test.dart
```
Expected: passes.

---

## Task 5: `LinkOptionService` online passthrough

**Files:**
- Modify: `frappe-mobile-sdk/lib/src/services/link_option_service.dart`
- Create: `frappe-mobile-sdk/test/services/link_option_service_online_test.dart`

- [ ] **Step 5.1: Add `offlineMode` parameter and short-circuit**

```dart
final OfflineMode offlineMode;
final FrappeClient client;

LinkOptionService(
  this._resolver,
  this._metaResolver, {
  required this.offlineMode,
  required this.client,
});
```

In each public lookup method (e.g. `getLinkOptions`, `searchLinkOptions`), short-circuit at the top:

```dart
if (!offlineMode.enabled) {
  final rows = await client.document.getDocList(
    targetDoctype,
    filters: filters,
    limitPageLength: limit,
  );
  return _mapRowsToLinkOptions(rows);
}
```

`_mapRowsToLinkOptions` is whatever existing transformation the service applies inside its DB-first branch — extract it if needed. Do NOT write to `link_options`.

- [ ] **Step 5.2: Write test**

Path: `frappe-mobile-sdk/test/services/link_option_service_online_test.dart`

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/models/offline_mode.dart';
import 'package:frappe_mobile_sdk/src/services/link_option_service.dart';

import '../helpers/fake_frappe_client.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('online mode returns options from REST with no link_options write',
      () async {
    final db = await AppDatabase.inMemoryDatabase();
    final client = FakeFrappeClient()
      ..stubGetDocList('Customer', [
        {'name': 'CUST-1', 'customer_name': 'Acme'},
      ]);

    // Resolver / metaResolver are unreachable when offline mode is off.
    final svc = LinkOptionService(
      _UnreachableResolver(),
      (_) async => throw 'meta not used',
      offlineMode: const OfflineMode(enabled: false, isPersisted: true),
      client: client,
    );

    final options = await svc.getLinkOptions(targetDoctype: 'Customer');
    expect(options.length, 1);
    final linkOptionRows =
        await db.rawDatabase.rawQuery('SELECT * FROM link_options');
    expect(linkOptionRows, isEmpty);
    await db.close();
  });
}

class _UnreachableResolver { ... }
```

Adjust `getLinkOptions(...)` parameter names and the resolver placeholder type to match the actual service surface.

- [ ] **Step 5.3: Run and verify pass**

```
flutter test test/services/link_option_service_online_test.dart
```
Expected: passes.

---

## Task 6: `_resolveBootMode` and residue helper on `FrappeSDK`

**Files:**
- Modify: `frappe-mobile-sdk/lib/src/sdk/frappe_sdk.dart`

- [ ] **Step 6.1: Add field and imports**

At the top:
```dart
import '../models/offline_mode.dart';
```

Inside the class, alongside other private fields:
```dart
late OfflineMode _offlineMode;
```

- [ ] **Step 6.2: Add `_resolveBootMode`**

Insert near the other private helpers:

```dart
/// Resolves the session-bound offline mode from the persisted record.
///
/// - Persisted value present → use it verbatim.
/// - Unpersisted + residue on disk → assume legacy offline install,
///   boot offline (P2 conservative guard; P3 keeps this branch but adds
///   a transition handler for the persisted-online + residue case).
/// - Unpersisted + no residue → fresh install, boot online (spec default).
Future<OfflineMode> _resolveBootMode(OfflineMode persisted) async {
  if (persisted.isPersisted) {
    // P2 RESIDUE GUARD: if server says online but residue exists, stay
    // offline anyway and log a warning. Replaced in P3 by a real drain
    // flow that wipes the residue before honoring the persisted value.
    if (!persisted.enabled && await _hasResidualOfflineState()) {
      // ignore: avoid_print
      print(
        'FrappeSDK: residue detected with offline_enabled=false — '
        'staying offline this session. P3 will replace this guard with '
        'a drain/wipe transition.',
      );
      return const OfflineMode(enabled: true, isPersisted: true);
    }
    return persisted;
  }
  final hasResidue = await _hasResidualOfflineState();
  return OfflineMode(enabled: hasResidue, isPersisted: false);
}
```

- [ ] **Step 6.3: Add `_hasResidualOfflineState`**

```dart
/// Returns true iff any of the offline-only data structures contain
/// state from a previous offline-mode session.
Future<bool> _hasResidualOfflineState() async {
  if (_database == null) return false;
  final raw = _database!.rawDatabase;

  final tableRows = await raw.rawQuery(
    "SELECT name FROM sqlite_master "
    "WHERE type='table' AND name LIKE 'docs\\_\\_%' ESCAPE '\\' LIMIT 1",
  );
  if (tableRows.isNotEmpty) return true;

  final outboxRows = await raw.rawQuery('SELECT 1 FROM outbox LIMIT 1');
  if (outboxRows.isNotEmpty) return true;

  final attachRows =
      await raw.rawQuery('SELECT 1 FROM pending_attachments LIMIT 1');
  if (attachRows.isNotEmpty) return true;

  return false;
}
```

---

## Task 7: Wire `OfflineMode` into service construction in `initialize()`

**Files:**
- Modify: `frappe-mobile-sdk/lib/src/sdk/frappe_sdk.dart`

- [ ] **Step 7.1: Read persisted mode and resolve boot mode**

In `initialize()`, after `_authService = AuthService(); _authService!.initialize(...);`, replace the existing service construction block. Insert before the resolver build:

```dart
final persistedMode =
    await SdkMetaDao(_database!.rawDatabase).readOfflineMode();
_offlineMode = await _resolveBootMode(persistedMode);
```

- [ ] **Step 7.2: Pass `_offlineMode` into every service constructor**

Update the constructor calls to match the new required parameters added in Tasks 1, 3, 4, 5:

```dart
_repository = OfflineRepository(
  _database!,
  localWriter: localWriter,
  offlineMode: _offlineMode,
  client: _client!,
);
_syncService = SyncService(
  _client!,
  _repository!,
  _database!,
  getMobileUuid: () => _authService!.getOrCreateMobileUuid(),
  offlineMode: _offlineMode,
);
final resolver = UnifiedResolver(
  db: rawDb,
  metaDao: DoctypeMetaDao(rawDb),
  isOnline: () => _cachedOnline,
  backgroundFetch: (doctype, _) async {
    try { await syncSvc.pullSync(doctype: doctype); } catch (_) {}
  },
  metaResolver: metaFn,
  offlineMode: _offlineMode,
  client: _client!,
);
_linkOptionService = LinkOptionService(
  resolver,
  metaFn,
  offlineMode: _offlineMode,
  client: _client!,
);
```

- [ ] **Step 7.3: Update `forTesting` constructor**

Add an `OfflineMode` parameter with a default:

```dart
@visibleForTesting
FrappeSDK.forTesting(
  this.baseUrl,
  AppDatabase database, {
  OfflineMode offlineMode = OfflineMode.fallback,
}) : databaseAppName = null {
  _database = database;
  _offlineMode = offlineMode;
  _client = FrappeClient(baseUrl);
  _authService = AuthService.forTesting(_client!, database: database);
  _metaService = MetaService(_client!, _database!);
  final testMetaFn = _metaService!.getMeta;
  final testLocalWriter = LocalWriter(database.rawDatabase, testMetaFn);
  _repository = OfflineRepository(
    _database!,
    localWriter: testLocalWriter,
    offlineMode: offlineMode,
    client: _client!,
  );
  _permissionService = PermissionService(_client!, _database!);
  _translationService = TranslationService(_client!);
  _syncService = SyncService(
    _client!, _repository!, _database!,
    getMobileUuid: () async => 'test-uuid',
    offlineMode: offlineMode,
  );
  final testResolver = UnifiedResolver(
    db: database.rawDatabase,
    metaDao: DoctypeMetaDao(database.rawDatabase),
    isOnline: () => false,
    backgroundFetch: (_, __) async {},
    metaResolver: testMetaFn,
    offlineMode: offlineMode,
    client: _client!,
  );
  _linkOptionService = LinkOptionService(
    testResolver, testMetaFn,
    offlineMode: offlineMode,
    client: _client!,
  );
  _sessionUserService = SessionUserService(_database!.rawDatabase);
  _initialized = true;
}
```

- [ ] **Step 7.4: Run analyzer**

```
flutter analyze
```
Expected: no new errors.

---

## Task 8: Gate the closure pull in `_initialMetaAndDataSync`

**Files:**
- Modify: `frappe-mobile-sdk/lib/src/sdk/frappe_sdk.dart`

- [ ] **Step 8.1: Add the early return**

In `_initialMetaAndDataSync`, after the existing meta/permissions/translations block, insert a gate before the closure pull:

```dart
try { await _metaService!.resyncMobileConfiguration(); } catch (_) {}

if (!_offlineMode.enabled) return;   // online mode stops here

try {
  // existing closure pull body (entryPoints, closure, for-loop)
  ...
} catch (_) {
  // ignore data sync errors
}
```

The existing comment block above the closure pull stays. Just place the early-return immediately above it.

- [ ] **Step 8.2: Smoke-test analyzer**

```
flutter analyze
```
Expected: no new errors.

---

## Task 9: Boot-mode integration test

**Files:**
- Create: `frappe-mobile-sdk/test/sdk/frappe_sdk_boot_mode_test.dart`

- [ ] **Step 9.1: Write the test**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/database/daos/sdk_meta_dao.dart';
import 'package:frappe_mobile_sdk/src/models/offline_mode.dart';
import 'package:frappe_mobile_sdk/src/sdk/frappe_sdk.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('FrappeSDK._resolveBootMode (via initialize)', () {
    test('persisted online + no residue → online session', () async {
      final db = await AppDatabase.inMemoryDatabase();
      await SdkMetaDao(db.rawDatabase).writeOfflineMode(
          enabled: false, setAtMs: 1);
      final sdk = FrappeSDK.forTesting('http://localhost', db);
      expect(sdk.offlineModeForTesting.enabled, isFalse);
      expect(sdk.offlineModeForTesting.isPersisted, isTrue);
      await sdk.dispose();
      await db.close();
    });

    test('persisted offline → offline session', () async {
      final db = await AppDatabase.inMemoryDatabase();
      await SdkMetaDao(db.rawDatabase).writeOfflineMode(
          enabled: true, setAtMs: 1);
      final sdk = FrappeSDK.forTesting(
        'http://localhost', db,
        offlineMode: const OfflineMode(enabled: true, isPersisted: true),
      );
      expect(sdk.offlineModeForTesting.enabled, isTrue);
      await sdk.dispose();
      await db.close();
    });

    test('unpersisted + no residue → online (fresh install)', () async {
      final db = await AppDatabase.inMemoryDatabase();
      final sdk = FrappeSDK.forTesting('http://localhost', db);
      expect(sdk.offlineModeForTesting.enabled, isFalse);
      expect(sdk.offlineModeForTesting.isPersisted, isFalse);
      await sdk.dispose();
      await db.close();
    });
  });
}
```

`offlineModeForTesting` is a thin getter to expose `_offlineMode` for tests:

```dart
@visibleForTesting
OfflineMode get offlineModeForTesting => _offlineMode;
```

The boot tests against `forTesting` mostly assert the constructor wiring; the residue-guard branch is exercised in the next task because `forTesting` does not call `_resolveBootMode`.

- [ ] **Step 9.2: Run and verify pass**

```
flutter test test/sdk/frappe_sdk_boot_mode_test.dart
```
Expected: passes.

---

## Task 10: Residue guard test

**Files:**
- Create: `frappe-mobile-sdk/test/sdk/frappe_sdk_residue_guard_test.dart`

- [ ] **Step 10.1: Expose private helpers for testing**

In `frappe-mobile-sdk/lib/src/sdk/frappe_sdk.dart`, add `@visibleForTesting` wrappers near the bottom of the class:

```dart
@visibleForTesting
Future<bool> hasResidualOfflineStateForTesting() => _hasResidualOfflineState();

@visibleForTesting
Future<OfflineMode> resolveBootModeForTesting(OfflineMode persisted) =>
    _resolveBootMode(persisted);
```

- [ ] **Step 10.2: Write the test**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/models/offline_mode.dart';
import 'package:frappe_mobile_sdk/src/sdk/frappe_sdk.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('residue guard (P2)', () {
    test('persisted=online + residue (docs__ table) → guarded offline', () async {
      final db = await AppDatabase.inMemoryDatabase();
      // Seed a residue table.
      await db.rawDatabase
          .execute('CREATE TABLE docs__customer (mobile_uuid TEXT)');
      final sdk = FrappeSDK.forTesting('http://localhost', db);

      final mode = await sdk.resolveBootModeForTesting(
        const OfflineMode(enabled: false, isPersisted: true),
      );
      expect(mode.enabled, isTrue,
          reason: 'P2 guard keeps offline mode when residue exists');
      expect(mode.isPersisted, isTrue);

      await sdk.dispose();
      await db.close();
    });

    test('persisted=online + no residue → online', () async {
      final db = await AppDatabase.inMemoryDatabase();
      final sdk = FrappeSDK.forTesting('http://localhost', db);

      final mode = await sdk.resolveBootModeForTesting(
        const OfflineMode(enabled: false, isPersisted: true),
      );
      expect(mode.enabled, isFalse);

      await sdk.dispose();
      await db.close();
    });

    test('unpersisted + outbox row → offline', () async {
      final db = await AppDatabase.inMemoryDatabase();
      await db.rawDatabase.execute(
        "INSERT INTO outbox (doctype, mobile_uuid, operation, state, created_at) "
        "VALUES ('Customer', 'uuid-1', 'create', 'pending', 1)",
      );
      final sdk = FrappeSDK.forTesting('http://localhost', db);

      final mode = await sdk.resolveBootModeForTesting(OfflineMode.fallback);
      expect(mode.enabled, isTrue);
      expect(mode.isPersisted, isFalse);

      await sdk.dispose();
      await db.close();
    });

    test('unpersisted + no residue → online', () async {
      final db = await AppDatabase.inMemoryDatabase();
      final sdk = FrappeSDK.forTesting('http://localhost', db);
      final mode = await sdk.resolveBootModeForTesting(OfflineMode.fallback);
      expect(mode.enabled, isFalse);
      expect(mode.isPersisted, isFalse);
      await sdk.dispose();
      await db.close();
    });
  });
}
```

- [ ] **Step 10.3: Run and verify pass**

```
flutter test test/sdk/frappe_sdk_residue_guard_test.dart
```
Expected: all four tests pass.

---

## Self-review

```
cd /home/omprakash/Desktop/snf/frappe-mobile-sdk && flutter analyze && flutter test
```

Expected: no new analyzer warnings; full SDK suite passes.

**Spec coverage check (P2):**

| Spec section | Task |
|---|---|
| §4.3 — `_resolveBootMode` | 6, 9, 10 |
| §4.3 — `_hasResidualOfflineState` | 6, 10 |
| §4.4 — service construction with offline=false | 7 |
| §5.1 — `UnifiedResolver._onlinePassthrough` | 1, 2 |
| §5.2 — `OfflineRepository` online passthrough | 3 |
| §5.3 — `SyncService` no-op | 4 |
| §5.4 — `LinkOptionService` online passthrough | 5 |
| §5.6 — `_initialMetaAndDataSync` closure-pull gate | 8 |
| §10.3 — `forTesting` seam with `offlineMode` parameter | 7 |

**Conservative residue guard:** §6 of this plan implements the temporary guard. P3 replaces it with the real drain/wipe flow (P3 §1 will edit the same `_resolveBootMode` to remove the early-offline return, instead invoking `_runOfflineToOnlineTransition`). The guard is intentionally noisy (prints a warning) so the upgrade path is visible in logs.

**Ready to ship as P2:** the SDK now respects the persisted flag for fresh installs (the dominant case). Existing offline users with residue stay offline regardless of the server flag — strictly safer than the current main-branch behavior, which always boots offline. P3 unblocks the offline → online transition path.
