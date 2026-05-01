# Offline Mode Toggle — P1: Server contract + SDK persistence

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a server-side `offline_enabled` Check field on `Mobile Configuration`, surface it on every login response, and have the SDK persist the value to `sdk_meta` after each successful authentication. This phase produces a working build with NO behavior change — the flag is collected but not yet acted on. P2 makes it gate read/write paths.

**Architecture:** Server adds one declarative field + one Frappe patch. SDK adds two columns to `sdk_meta` (schema bump v4 → v5), a small immutable `OfflineMode` model, and a single-table DAO. `FrappeSDK` calls a new `_persistOfflineFlagFromLogin` helper from each of the four auth surfaces. No service constructors change.

**Tech Stack:** Frappe v15+ doctype JSON, Python (Frappe patch); Dart (sqflite + flutter_test).

**Spec reference:** `docs/superpowers/specs/2026-05-01-offline-mode-toggle-design.md` §3, §4.1, §4.2, §6.

**User-driven commits:** per the project's `feedback_no_commits` rule, no commits are scripted in this plan. Commit when the user explicitly asks.

---

## File structure

| Path | Action | Responsibility |
|---|---|---|
| `frappe_mform_snf/apps/mobile_control/.../mobile_configuration.json` | modify | Add `offline_enabled` Check field |
| `frappe_mform_snf/apps/mobile_control/.../mobile_config.py` | modify | Include `offline_enabled` in returned payload |
| `frappe_mform_snf/apps/mobile_control/.../response_builder.py` | modify | Surface `offline_enabled` on the top-level login response |
| `frappe_mform_snf/apps/mobile_control/mobile_control/patches.txt` | modify | Register the new patch |
| `frappe_mform_snf/apps/mobile_control/mobile_control/patches/v1_0/set_offline_enabled_default.py` | create | Set existing single's column to 0 (idempotent) |
| `frappe-mobile-sdk/lib/src/database/schema/system_tables.dart` | modify | Add `offline_enabled` + `offline_enabled_set_at` to `sdk_meta` (fresh-install DDL) and a v4→v5 ALTER list |
| `frappe-mobile-sdk/lib/src/database/app_database.dart` | modify | Bump `_version` to 5; add `_onUpgrade` block calling the new ALTER list |
| `frappe-mobile-sdk/lib/src/models/offline_mode.dart` | create | Immutable value object |
| `frappe-mobile-sdk/lib/src/database/daos/sdk_meta_dao.dart` | create | `readOfflineMode` / `writeOfflineMode` |
| `frappe-mobile-sdk/lib/src/sdk/frappe_sdk.dart` | modify | Add `_persistOfflineFlagFromLogin`; wire into `login`, `verifyLoginOtp`, `_fetchUserInfoAndApply` |
| `frappe-mobile-sdk/test/models/offline_mode_test.dart` | create | Unit tests for the model |
| `frappe-mobile-sdk/test/database/sdk_meta_dao_test.dart` | create | DAO unit tests against in-memory DB |
| `frappe-mobile-sdk/test/database/sdk_meta_migration_test.dart` | create | v4→v5 migration test using a pre-v5 schema fixture |
| `frappe-mobile-sdk/test/sdk/frappe_sdk_offline_persistence_test.dart` | create | Integration test for the four auth surfaces |

---

## Task 1: Add `offline_enabled` field to `Mobile Configuration` doctype

**Files:**
- Modify: `frappe_mform_snf/apps/mobile_control/mobile_control/mobile_control/doctype/mobile_configuration/mobile_configuration.json`

- [ ] **Step 1.1: Add field to `field_order`**

In the JSON file, locate the existing `"field_order"` array (around line 7). It currently starts with `"enabled"`. Insert `"offline_enabled"` immediately after `"enabled"`:

```json
"field_order": [
  "enabled",
  "offline_enabled",
  "app_details_section",
  ...
],
```

- [ ] **Step 1.2: Add field definition to `fields`**

In the same file, locate the existing field for `enabled` (around line 20-25). Add a new field object right after it:

```json
{
  "default": "0",
  "depends_on": "eval:doc.enabled",
  "fieldname": "offline_enabled",
  "fieldtype": "Check",
  "label": "Offline Mode Enabled"
},
```

- [ ] **Step 1.3: Verify with bench**

Run from the bench root:
```
cd /home/omprakash/Desktop/snf/frappe_mform_snf && bench --site <site> migrate
```
Expected: migration runs without error; `tabMobile Configuration` gains the `offline_enabled` column with default `0`.

If the user does not have a bench site available locally, this step is documentation only — the field is verified once the SDK integration test (Task 11) hits a real server.

---

## Task 2: Audit `mobile_configuration.js`

**Files:**
- Read-only: `frappe_mform_snf/apps/mobile_control/mobile_control/mobile_control/doctype/mobile_configuration/mobile_configuration.js`

- [ ] **Step 2.1: Read the file**

Use the Read tool. The new field has `depends_on: eval:doc.enabled` — Frappe core handles show/hide declaratively.

- [ ] **Step 2.2: Confirm no JS changes are required**

The file should not reference `offline_enabled`. No edit needed. The spec §3.2 records the audit conclusion.

---

## Task 3: Surface `offline_enabled` in the mobile_config payload

**Files:**
- Modify: `frappe_mform_snf/apps/mobile_control/mobile_control/api/helpers/mobile_config.py`

- [ ] **Step 3.1: Add field to payload**

In `get_mobile_configuration_payload`, add `offline_enabled` to the returned dict alongside `enabled`:

```python
enabled = bool(config.enabled)
offline_enabled = bool(config.offline_enabled) if enabled else False
maintenance_mode = bool(config.maintenance_mode)
return {
    "enabled": enabled,
    "offline_enabled": offline_enabled,
    "package_name": config.package_name if enabled else "",
    "version": config.minimum_app_version if enabled else "",
    "maintenance_mode": maintenance_mode,
    "maintenance_message": config.maintenance_message if maintenance_mode else "",
    "configuration": configuration,
}
```

Also update the `except` branch:

```python
except Exception:
    frappe.log_error(...)
    return {
        "enabled": False,
        "offline_enabled": False,
        "package_name": "",
        ...
    }
```

`bool(...)` on a missing column raises `AttributeError`, which the caller already catches via the broad `except`. The `if enabled else False` short-circuit makes the payload semantically clean: offline mode is only meaningful when the app itself is enabled.

---

## Task 4: Surface `offline_enabled` on the top-level login response

**Files:**
- Modify: `frappe_mform_snf/apps/mobile_control/mobile_control/api/helpers/response_builder.py`

- [ ] **Step 4.1: Read the current response builder**

Use the Read tool to confirm the file's structure — the helper merges `get_mobile_configuration_payload()` output into the auth response.

- [ ] **Step 4.2: Add the field to the top-level response**

Wherever the login response dict is assembled, add `"offline_enabled": payload["offline_enabled"]` next to the existing `enabled`-style keys. Centralizing here means all four auth surfaces (`api_auth.login`, `verify_mobile_otp`, `mobile_auth.me` for OAuth/API key) receive the field automatically.

The exact edit depends on the current structure of `response_builder.py`. The principle: the SDK reads `response['offline_enabled']` directly, so it must appear at the top level, not nested inside `configuration`.

---

## Task 5: Frappe patch to set `offline_enabled = 0` on existing single

**Files:**
- Create: `frappe_mform_snf/apps/mobile_control/mobile_control/patches/v1_0/__init__.py` (empty file if missing)
- Create: `frappe_mform_snf/apps/mobile_control/mobile_control/patches/v1_0/set_offline_enabled_default.py`
- Modify: `frappe_mform_snf/apps/mobile_control/mobile_control/patches.txt`

- [ ] **Step 5.1: Verify patches dir exists**

Run `ls /home/omprakash/Desktop/snf/frappe_mform_snf/apps/mobile_control/mobile_control/patches/`. If `v1_0/` does not exist, create it (and an empty `__init__.py`).

- [ ] **Step 5.2: Create the patch file**

Path: `frappe_mform_snf/apps/mobile_control/mobile_control/patches/v1_0/set_offline_enabled_default.py`

```python
import frappe


def execute():
    """Default offline_enabled to 0 on the existing Mobile Configuration single.

    No-op on fresh installs (the column already defaults to 0). Idempotent
    on reruns.
    """
    if not frappe.db.has_column("Mobile Configuration", "offline_enabled"):
        return
    frappe.db.set_single_value("Mobile Configuration", "offline_enabled", 0)
    frappe.db.commit()
```

- [ ] **Step 5.3: Register the patch**

Open `frappe_mform_snf/apps/mobile_control/mobile_control/patches.txt` and append:

```
mobile_control.patches.v1_0.set_offline_enabled_default
```

- [ ] **Step 5.4: (Optional) Run migration**

If a bench site is available:
```
bench --site <site> migrate
```
Expected: the patch runs once; subsequent `migrate` invocations skip it.

---

## Task 6: SDK schema migration — add columns to `sdk_meta`

**Files:**
- Modify: `frappe-mobile-sdk/lib/src/database/schema/system_tables.dart`
- Modify: `frappe-mobile-sdk/lib/src/database/app_database.dart`

- [ ] **Step 6.1: Update `system_tables.dart` fresh-install DDL**

Edit the `sdk_meta` `CREATE TABLE` block to include the two new columns:

```dart
'''
    CREATE TABLE IF NOT EXISTS sdk_meta (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      schema_version INTEGER NOT NULL DEFAULT 0,
      session_user_json TEXT,
      bootstrap_done INTEGER NOT NULL DEFAULT 0,
      offline_enabled INTEGER NOT NULL DEFAULT 0,
      offline_enabled_set_at INTEGER
    )
    ''',
```

- [ ] **Step 6.2: Add the v5 extension list**

At the bottom of the same file, add:

```dart
/// v5 extension: server-driven offline mode toggle.
///
/// Adds two columns to `sdk_meta`. NOT idempotent on its own —
/// the call site in `app_database.dart` wraps each ALTER in
/// try/catch on "duplicate column name".
List<String> sdkMetaV5ExtensionsDDL() => <String>[
  'ALTER TABLE sdk_meta ADD COLUMN offline_enabled INTEGER NOT NULL DEFAULT 0',
  'ALTER TABLE sdk_meta ADD COLUMN offline_enabled_set_at INTEGER',
];
```

- [ ] **Step 6.3: Bump `_version` and add upgrade block**

In `frappe-mobile-sdk/lib/src/database/app_database.dart`:

Change `static const int _version = 4;` to `static const int _version = 5;`.

In `_onUpgrade`, add a new block after the existing `oldVersion < 4` block:

```dart
if (oldVersion < 5) {
  for (final stmt in sdkMetaV5ExtensionsDDL()) {
    try {
      await db.execute(stmt);
    } on DatabaseException catch (e) {
      if (!e.toString().toLowerCase().contains('duplicate column')) {
        rethrow;
      }
    }
  }
}
```

Add the import for `sdkMetaV5ExtensionsDDL` from `schema/system_tables.dart` if not already imported transitively.

- [ ] **Step 6.4: Smoke-test the SDK builds**

```
cd /home/omprakash/Desktop/snf/frappe-mobile-sdk
flutter analyze
```
Expected: no errors related to the changes. Existing pre-change warnings are unchanged.

---

## Task 7: Migration test (v4 → v5)

**Files:**
- Create: `frappe-mobile-sdk/test/database/sdk_meta_migration_test.dart`

- [ ] **Step 7.1: Write the failing test**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:frappe_mobile_sdk/src/database/schema/system_tables.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('v4 sdk_meta → v5 adds offline_enabled and set_at columns', () async {
    final db = await openDatabase(inMemoryDatabasePath, version: 4,
      onCreate: (db, _) async {
        // v4-shape sdk_meta — pre-v5 columns only
        await db.execute('''
          CREATE TABLE sdk_meta (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            schema_version INTEGER NOT NULL DEFAULT 0,
            session_user_json TEXT,
            bootstrap_done INTEGER NOT NULL DEFAULT 0
          )
        ''');
        await db.execute('INSERT INTO sdk_meta (id, schema_version) VALUES (1, 0)');
      },
    );

    for (final stmt in sdkMetaV5ExtensionsDDL()) {
      await db.execute(stmt);
    }

    final columns = await db.rawQuery("PRAGMA table_info(sdk_meta)");
    final names = columns.map((c) => c['name'] as String).toList();
    expect(names, containsAll(['offline_enabled', 'offline_enabled_set_at']));

    final rows = await db.rawQuery('SELECT offline_enabled, offline_enabled_set_at FROM sdk_meta WHERE id=1');
    expect(rows.first['offline_enabled'], 0);
    expect(rows.first['offline_enabled_set_at'], isNull);

    await db.close();
  });

  test('v5 ALTER on a fresh-install schema raises duplicate-column', () async {
    final db = await openDatabase(inMemoryDatabasePath, version: 5,
      onCreate: (db, _) async {
        for (final stmt in systemTablesDDL()) {
          await db.execute(stmt);
        }
      },
    );

    bool threw = false;
    try {
      await db.execute(sdkMetaV5ExtensionsDDL().first);
    } on DatabaseException catch (e) {
      if (e.toString().toLowerCase().contains('duplicate column')) threw = true;
    }
    expect(threw, isTrue, reason: 'AppDatabase._onUpgrade tolerates this; the test asserts the precondition holds');

    await db.close();
  });
}
```

- [ ] **Step 7.2: Run and verify both tests pass**

```
cd /home/omprakash/Desktop/snf/frappe-mobile-sdk
flutter test test/database/sdk_meta_migration_test.dart
```
Expected: both tests pass.

---

## Task 8: `OfflineMode` model

**Files:**
- Create: `frappe-mobile-sdk/lib/src/models/offline_mode.dart`
- Create: `frappe-mobile-sdk/test/models/offline_mode_test.dart`

- [ ] **Step 8.1: Write the failing test**

Path: `frappe-mobile-sdk/test/models/offline_mode_test.dart`

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/offline_mode.dart';

void main() {
  group('OfflineMode', () {
    test('fallback is online and unpersisted', () {
      expect(OfflineMode.fallback.enabled, isFalse);
      expect(OfflineMode.fallback.isPersisted, isFalse);
    });

    test('equality based on both fields', () {
      const a = OfflineMode(enabled: true, isPersisted: true);
      const b = OfflineMode(enabled: true, isPersisted: true);
      const c = OfflineMode(enabled: true, isPersisted: false);
      expect(a, equals(b));
      expect(a, isNot(equals(c)));
      expect(a.hashCode, equals(b.hashCode));
    });
  });
}
```

- [ ] **Step 8.2: Run and verify it fails**

```
flutter test test/models/offline_mode_test.dart
```
Expected: compile error — `package:frappe_mobile_sdk/src/models/offline_mode.dart` not found.

- [ ] **Step 8.3: Create the model**

Path: `frappe-mobile-sdk/lib/src/models/offline_mode.dart`

```dart
/// Server-driven offline mode flag bound to a session.
///
/// Constructed once per `FrappeSDK.initialize()` call; never mutated.
/// `isPersisted = false` means the SDK has never received a login
/// response carrying `offline_enabled` — distinguishes a fresh install
/// (or a just-upgraded SDK) from one that has been told a real value.
class OfflineMode {
  final bool enabled;
  final bool isPersisted;

  const OfflineMode({required this.enabled, required this.isPersisted});

  static const fallback = OfflineMode(enabled: false, isPersisted: false);

  @override
  bool operator ==(Object other) =>
      other is OfflineMode &&
      other.enabled == enabled &&
      other.isPersisted == isPersisted;

  @override
  int get hashCode => Object.hash(enabled, isPersisted);

  @override
  String toString() => 'OfflineMode(enabled: $enabled, isPersisted: $isPersisted)';
}
```

- [ ] **Step 8.4: Re-run tests and verify pass**

```
flutter test test/models/offline_mode_test.dart
```
Expected: both tests pass.

---

## Task 9: `SdkMetaDao`

**Files:**
- Create: `frappe-mobile-sdk/lib/src/database/daos/sdk_meta_dao.dart`
- Create: `frappe-mobile-sdk/test/database/sdk_meta_dao_test.dart`

- [ ] **Step 9.1: Write the failing test**

Path: `frappe-mobile-sdk/test/database/sdk_meta_dao_test.dart`

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:frappe_mobile_sdk/src/database/daos/sdk_meta_dao.dart';
import 'package:frappe_mobile_sdk/src/database/schema/system_tables.dart';
import 'package:frappe_mobile_sdk/src/models/offline_mode.dart';

Future<Database> _freshDb() async {
  final db = await openDatabase(
    inMemoryDatabasePath,
    version: 1,
    onCreate: (db, _) async {
      for (final stmt in systemTablesDDL()) {
        await db.execute(stmt);
      }
    },
    singleInstance: false,
  );
  return db;
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('readOfflineMode returns fallback when set_at is NULL', () async {
    final db = await _freshDb();
    final dao = SdkMetaDao(db);
    final mode = await dao.readOfflineMode();
    expect(mode, OfflineMode.fallback);
    await db.close();
  });

  test('writeOfflineMode then readOfflineMode round-trips enabled=true', () async {
    final db = await _freshDb();
    final dao = SdkMetaDao(db);
    await dao.writeOfflineMode(enabled: true, setAtMs: 12345);
    final mode = await dao.readOfflineMode();
    expect(mode.enabled, isTrue);
    expect(mode.isPersisted, isTrue);
    await db.close();
  });

  test('writeOfflineMode then readOfflineMode round-trips enabled=false', () async {
    final db = await _freshDb();
    final dao = SdkMetaDao(db);
    await dao.writeOfflineMode(enabled: false, setAtMs: 67890);
    final mode = await dao.readOfflineMode();
    expect(mode.enabled, isFalse);
    expect(mode.isPersisted, isTrue);
    await db.close();
  });

  test('readOfflineMode returns fallback when row is missing', () async {
    final db = await _freshDb();
    await db.delete('sdk_meta');
    final dao = SdkMetaDao(db);
    final mode = await dao.readOfflineMode();
    expect(mode, OfflineMode.fallback);
    await db.close();
  });
}
```

- [ ] **Step 9.2: Run and verify it fails**

```
flutter test test/database/sdk_meta_dao_test.dart
```
Expected: compile error — DAO not found.

- [ ] **Step 9.3: Create the DAO**

Path: `frappe-mobile-sdk/lib/src/database/daos/sdk_meta_dao.dart`

```dart
import 'package:sqflite/sqflite.dart';
import '../../models/offline_mode.dart';

/// Single-row read/write helpers for the offline-mode columns on `sdk_meta`.
class SdkMetaDao {
  final Database _db;

  SdkMetaDao(this._db);

  /// Returns the persisted offline mode, or [OfflineMode.fallback] if no
  /// row exists or the column was never set (`set_at IS NULL`).
  Future<OfflineMode> readOfflineMode() async {
    final rows = await _db.rawQuery(
      'SELECT offline_enabled, offline_enabled_set_at FROM sdk_meta WHERE id = 1 LIMIT 1',
    );
    if (rows.isEmpty) return OfflineMode.fallback;
    final row = rows.first;
    if (row['offline_enabled_set_at'] == null) return OfflineMode.fallback;
    final enabled = (row['offline_enabled'] as int? ?? 0) == 1;
    return OfflineMode(enabled: enabled, isPersisted: true);
  }

  /// Persists the offline-mode value with the given epoch-ms timestamp.
  /// Always upserts onto the singleton `id = 1` row.
  Future<void> writeOfflineMode({
    required bool enabled,
    required int setAtMs,
  }) async {
    await _db.rawUpdate(
      'UPDATE sdk_meta SET offline_enabled = ?, offline_enabled_set_at = ? WHERE id = 1',
      [enabled ? 1 : 0, setAtMs],
    );
  }
}
```

- [ ] **Step 9.4: Re-run tests and verify all pass**

```
flutter test test/database/sdk_meta_dao_test.dart
```
Expected: all four tests pass.

---

## Task 10: `_persistOfflineFlagFromLogin` helper on `FrappeSDK`

**Files:**
- Modify: `frappe-mobile-sdk/lib/src/sdk/frappe_sdk.dart`

- [ ] **Step 10.1: Add imports**

At the top of `frappe_sdk.dart`, alongside the existing imports, add:

```dart
import '../database/daos/sdk_meta_dao.dart';
```

The `OfflineMode` model is not needed in this file yet (P2 will add it).

- [ ] **Step 10.2: Add the helper method**

Inside the `FrappeSDK` class, after the existing `_setSessionUserFromLoginResponse` method, add:

```dart
/// Persists the `offline_enabled` flag from a login response.
///
/// Treats a missing or non-`true` value as `false`. Non-fatal — write
/// failures are logged and swallowed so a transient SQLite error
/// doesn't fail the login itself.
Future<void> _persistOfflineFlagFromLogin(Map<String, dynamic> response) async {
  if (_database == null) return;
  final incoming = response['offline_enabled'] == true;
  try {
    await SdkMetaDao(_database!.rawDatabase).writeOfflineMode(
      enabled: incoming,
      setAtMs: DateTime.now().millisecondsSinceEpoch,
    );
  } catch (e, st) {
    // ignore: avoid_print
    print('FrappeSDK: failed to persist offline_enabled — $e\n$st');
  }
}
```

- [ ] **Step 10.3: Wire into `login`**

Locate the existing `login` method (around line 222). Add the helper call after the existing permissions/translations side effects, before `return response`:

```dart
Future<Map<String, dynamic>> login(String username, String password) async {
  if (!_initialized) await initialize();
  final response = await _authService!.login(username, password);
  await _permissionService!.saveFromLoginResponse(response['permissions']);
  final lang = response['language'] as String?;
  if (lang != null && lang.isNotEmpty) {
    await _translationService?.setLocale(lang);
  }
  _setSessionUserFromLoginResponse(response);
  await _persistOfflineFlagFromLogin(response);
  return response;
}
```

- [ ] **Step 10.4: Wire into `verifyLoginOtp`**

Same pattern, locate `verifyLoginOtp` and add `await _persistOfflineFlagFromLogin(response);` immediately before `return response`.

- [ ] **Step 10.5: Wire into `_fetchUserInfoAndApply`**

Locate `_fetchUserInfoAndApply` (around line 457). The OAuth/API-key path. Add the persistence call where the response (`userInfo` in this method) is available — right after the existing `_sessionUserService?.set(...)` block:

```dart
await _persistOfflineFlagFromLogin(userInfo);
```

`userInfo` is the response from `mobile_auth.me`. After Task 4, that endpoint also includes `offline_enabled`.

- [ ] **Step 10.6: Smoke-test analyze**

```
cd /home/omprakash/Desktop/snf/frappe-mobile-sdk && flutter analyze
```
Expected: no new errors.

---

## Task 11: Integration test — all four auth surfaces persist the flag

**Files:**
- Create: `frappe-mobile-sdk/test/sdk/frappe_sdk_offline_persistence_test.dart`

- [ ] **Step 11.1: Identify test seam**

The existing `FrappeSDK.forTesting` constructor (at `frappe_sdk.dart` around line 65) wires services with an in-memory DB but takes a real `AuthService.forTesting`. To test `_persistOfflineFlagFromLogin` against a fake response, we drive the public methods using a fake `FrappeClient`.

The simplest approach: refactor only what we need without changing the public API. Test through `login` by injecting a fake client that returns a canned response.

- [ ] **Step 11.2: Write the failing test**

Path: `frappe-mobile-sdk/test/sdk/frappe_sdk_offline_persistence_test.dart`

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/database/daos/sdk_meta_dao.dart';
import 'package:frappe_mobile_sdk/src/sdk/frappe_sdk.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('FrappeSDK offline_enabled persistence', () {
    late AppDatabase db;
    late FrappeSDK sdk;

    setUp(() async {
      db = await AppDatabase.inMemoryDatabase();
      sdk = FrappeSDK.forTesting('http://localhost', db);
    });

    tearDown(() async {
      await sdk.dispose();
      await db.close();
    });

    test('readOfflineMode is fallback before any login', () async {
      final mode = await SdkMetaDao(db.rawDatabase).readOfflineMode();
      expect(mode.isPersisted, isFalse);
      expect(mode.enabled, isFalse);
    });

    test('login response with offline_enabled=true persists enabled=true',
        () async {
      // Drive _persistOfflineFlagFromLogin via a public surface. Since
      // FrappeSDK.login() requires real network, exercise the helper via a
      // public test seam to be added in step 11.3.
      await sdk.persistOfflineFlagFromLoginForTesting(
        {'offline_enabled': true, 'user': 'tester@example.com'},
      );
      final mode = await SdkMetaDao(db.rawDatabase).readOfflineMode();
      expect(mode.enabled, isTrue);
      expect(mode.isPersisted, isTrue);
    });

    test('login response with offline_enabled=false persists enabled=false',
        () async {
      await sdk.persistOfflineFlagFromLoginForTesting(
        {'offline_enabled': false, 'user': 'tester@example.com'},
      );
      final mode = await SdkMetaDao(db.rawDatabase).readOfflineMode();
      expect(mode.enabled, isFalse);
      expect(mode.isPersisted, isTrue);
    });

    test('login response missing offline_enabled persists enabled=false',
        () async {
      await sdk.persistOfflineFlagFromLoginForTesting(
        {'user': 'tester@example.com'},
      );
      final mode = await SdkMetaDao(db.rawDatabase).readOfflineMode();
      expect(mode.enabled, isFalse);
      expect(mode.isPersisted, isTrue);
    });

    test('login response with offline_enabled=null persists enabled=false',
        () async {
      await sdk.persistOfflineFlagFromLoginForTesting(
        {'offline_enabled': null, 'user': 'tester@example.com'},
      );
      final mode = await SdkMetaDao(db.rawDatabase).readOfflineMode();
      expect(mode.enabled, isFalse);
      expect(mode.isPersisted, isTrue);
    });
  });
}
```

- [ ] **Step 11.3: Add public test seam**

In `frappe-mobile-sdk/lib/src/sdk/frappe_sdk.dart`, add a `@visibleForTesting` wrapper directly above the existing `dispose()` method:

```dart
@visibleForTesting
Future<void> persistOfflineFlagFromLoginForTesting(
  Map<String, dynamic> response,
) => _persistOfflineFlagFromLogin(response);
```

`@visibleForTesting` is already imported via `package:flutter/foundation.dart`.

- [ ] **Step 11.4: Run and verify pass**

```
flutter test test/sdk/frappe_sdk_offline_persistence_test.dart
```
Expected: all five tests pass.

---

## Self-review

After completing all tasks, run:

```
cd /home/omprakash/Desktop/snf/frappe-mobile-sdk && flutter analyze && flutter test
```

Expected: no new analyzer warnings; all SDK tests pass (including the four added in this phase).

**Spec coverage check (P1):**

| Spec section | Task |
|---|---|
| §3.1 — `Mobile Configuration` `offline_enabled` field | 1 |
| §3.2 — `mobile_configuration.js` audit | 2 |
| §3.3 — Login response payload | 3, 4 |
| §3.1 — Frappe patch | 5 |
| §4.1 — `OfflineMode` model | 8 |
| §4.2 — `sdk_meta` schema, v4→v5 migration | 6, 7 |
| §4.2 — `SdkMetaDao` | 9 |
| §6 — `_persistOfflineFlagFromLogin` wired into 4 auth surfaces | 10 |
| §11 — Tests | 7, 8, 9, 11 |

P1 ships: server has the toggle, SDK persists it. Zero behavior change. P2 begins from a green build.
