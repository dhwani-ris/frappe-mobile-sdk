# Attachment Pipeline v16 Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Implementation note (2026-05-01).** Live verification on Frappe v16.13 surfaced a constraint not anticipated when this plan was written: `apps/frappe/frappe/core/doctype/file/utils.py` (Frappe controller validation in `file.py:151`) rejects File insert with `attached_to_doctype` set but `attached_to_name` empty/NULL. The SDK therefore uploads **fully unattached** (no `dt`, no `dn`) instead of the partially-attached shape this plan originally specified. As a side effect, Frappe's stock `attach_files_to_document` (registered on `*.on_update`) handles parent-level relink for free, so the `mobile_control` hook only walks **child rows** (the part stock skips because v16 child rows save via raw `db_update()`). The migration was also consolidated from a two-step v3→v4→v5 into a single v3→v4 step (helper renamed `applyV4ToV5` → `applyV3ToV4Attachments`). The Architecture below reflects what was originally planned; the spec doc (`docs/superpowers/specs/2026-04-24-offline-first-sdk-design.md` §5.3) reflects what shipped.

**Goal:** Replace the orphan-creating `new-<doctype>` sentinel docname in attachment uploads with a deterministic relink flow that works against Frappe v16 — including child-row attachments. Files end up correctly linked to the actual server doc (parent or child row) without 60-minute time windows.

**Architecture (as originally planned):**
- **SDK** uploads each pending attachment with `dt=<owning_doctype>` (parent doctype OR child doctype) and **no** `dn`. Frappe creates a File row with `attached_to_doctype=<doctype>, attached_to_name=NULL` — fully unattached on the name dimension but permission-scoped to the doctype.
- **SDK** push payload then carries the returned `file_url` into the parent INSERT/UPDATE (existing `inlinePayload` flow).
- **mobile_control** registers a catch-all `doc_events["*"]["on_update"]` and `["on_update_after_submit"]` hook that walks the saved doc and its child rows; for each Attach/Attach Image field, finds the matching unattached File row by `(file_url, attached_to_doctype, attached_to_name IS NULL)` and rewires `attached_to_name = doc.name` (or `child.name`). Stock Frappe's `attach_files_to_document` continues to handle non-mobile uploads — they target a different "fully unattached" set, so there is no overlap.
- A schema delta on the SDK's `pending_attachments` table adds `top_parent_uuid` + `top_parent_doctype` so the push engine can discover ALL attachments (parent + child rows) for one outbox row in a single query. This is needed because today `findPendingForParent(row.mobileUuid)` would silently miss attachments queued against a child row's mobile_uuid.

This is a coordinated client+server change. Path B-simple (chosen 2026-05-01 in design discussion) — no new doctypes, no new custom fields on `File`, no `__temporary_name` 60-min window.

**Tech Stack:** Dart 3 / sqflite (mobile SDK), Python 3 / Frappe v16.13+ (mobile_control app), pytest-style flutter_test.

**References:**
- Spec: `docs/superpowers/specs/2026-04-24-offline-first-sdk-design.md` §5.3 (this plan replaces line 487's `new-<doctype>` sentinel with the unattached-File flow).
- v16 stock relinker: `apps/frappe/frappe/core/doctype/file/utils.py:312-373` (`attach_files_to_document`).
- v16 child rows skip lifecycle hooks: `apps/frappe/frappe/model/document.py:613-648` calls raw `db_update()`. Confirmed reason for needing our own hook.

---

## Pre-flight

- [ ] **Step 0.1: Diff against base branch**

Run: `cd /home/omprakash/Desktop/snf/frappe-mobile-sdk && git status && git diff feat/offline-first-snf --stat`

Confirm there are no unrelated WIP changes in `lib/src/sync/`, `lib/src/database/`, or `lib/src/models/`. If any, surface them before continuing.

- [ ] **Step 0.2: Confirm Frappe version**

Run: `grep '__version__' /home/omprakash/Desktop/snf/frappe_mform_snf/apps/frappe/frappe/__init__.py`

Expected: `__version__ = "16.13.0"` or higher. The plan depends on v16's `frappe/hooks.py:155-166` catch-all `on_update` and the `attach_files_to_document` semantics. If the version is older than 16, stop — `relink_mismatched_files` and child-table walking shape this design.

---

## File Structure

**SDK changes:**
- Modify `lib/src/database/schema/system_tables.dart` — add `top_parent_uuid`, `top_parent_doctype` columns + index to the `pending_attachments` DDL.
- Modify `lib/src/database/app_database.dart` — bump `_version` 4 → 5; add v4→v5 migration block.
- Modify `lib/src/models/pending_attachment.dart` — add `topParentUuid`, `topParentDoctype` fields + `fromMap` parsing.
- Modify `lib/src/database/daos/pending_attachment_dao.dart` — `enqueue` requires the new params; new `findPendingForTopParent` query.
- Modify `lib/src/sync/attachment_pipeline.dart` — drop sentinel docname; pass `dt=parent_doctype`, omit `dn`. Rename `uploadPendingFor` → `uploadPendingForTopParent`.
- Modify `lib/src/sync/push_engine.dart:233` — adopt the renamed method.

**SDK tests (existing):**
- Modify `test/database/daos/pending_attachment_dao_test.dart` — pass new required params; add `findPendingForTopParent` test.
- Modify `test/sync/attachment_pipeline_test.dart` — adopt new signature; assert uploader is called WITHOUT `docname`.

**SDK tests (new):**
- Create `test/database/migrations/v4_to_v5_test.dart` — verifies the schema migration adds columns + index and backfills existing rows.
- Create `test/sync/attachment_pipeline_child_discovery_test.dart` — verifies that pending rows queued against a child row's uuid are discovered when the push engine calls by `top_parent_uuid`.

**mobile_control changes:**
- Create `apps/mobile_control/mobile_control/attachment_relink.py` — the relink helper + catch-all hook.
- Modify `apps/mobile_control/mobile_control/hooks.py` — register hook on `*.on_update` and `*.on_update_after_submit`.

---

## Task 1: SDK schema delta + onCreate DDL

**Files:**
- Modify: `lib/src/database/schema/system_tables.dart` (the `pending_attachments` CREATE TABLE block)

- [ ] **Step 1.1: Update onCreate DDL**

Edit `lib/src/database/schema/system_tables.dart`. Replace the `pending_attachments` CREATE block and its index lines (current lines 32-53) with:

```dart
  '''
      CREATE TABLE IF NOT EXISTS pending_attachments (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        parent_uuid TEXT NOT NULL,
        parent_doctype TEXT NOT NULL,
        parent_fieldname TEXT NOT NULL,
        top_parent_uuid TEXT,
        top_parent_doctype TEXT,
        local_path TEXT NOT NULL,
        file_name TEXT,
        mime_type TEXT,
        is_private INTEGER NOT NULL DEFAULT 1,
        size_bytes INTEGER,
        state TEXT NOT NULL,
        retry_count INTEGER NOT NULL DEFAULT 0,
        last_attempt_at INTEGER,
        error_message TEXT,
        server_file_name TEXT,
        server_file_url TEXT,
        created_at INTEGER NOT NULL
      )
      ''',
  'CREATE INDEX IF NOT EXISTS ix_attach_state ON pending_attachments(state)',
  'CREATE INDEX IF NOT EXISTS ix_attach_parent ON pending_attachments(parent_uuid, parent_fieldname)',
  'CREATE INDEX IF NOT EXISTS ix_attach_top_parent ON pending_attachments(top_parent_uuid, state)',
```

The two new columns are nullable in the schema (SQLite's `ALTER TABLE ADD COLUMN` can't add `NOT NULL` without a `DEFAULT`, so fresh and migrated databases would otherwise diverge). Non-null is enforced at the **DAO level** in Task 4 — `enqueue` requires both as `String` parameters. Existing rows are backfilled in the migration, and no production caller writes to this table outside the DAO.

---

## Task 2: SDK schema migration v4 → v5

**Files:**
- Create: `test/database/migrations/v4_to_v5_test.dart`
- Modify: `lib/src/database/app_database.dart` (`_version` constant + `_onUpgrade`)

- [ ] **Step 2.1: Write the failing migration test**

Create `test/database/migrations/v4_to_v5_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('v4 → v5 adds top_parent_uuid + top_parent_doctype + index, '
      'backfills from parent_uuid/parent_doctype', () async {
    final db = await databaseFactory.openDatabase(inMemoryDatabasePath);

    // Reproduce the v4 pending_attachments shape (no top_parent_* columns).
    await db.execute('''
      CREATE TABLE pending_attachments (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        parent_uuid TEXT NOT NULL,
        parent_doctype TEXT NOT NULL,
        parent_fieldname TEXT NOT NULL,
        local_path TEXT NOT NULL,
        file_name TEXT,
        mime_type TEXT,
        is_private INTEGER NOT NULL DEFAULT 1,
        size_bytes INTEGER,
        state TEXT NOT NULL,
        retry_count INTEGER NOT NULL DEFAULT 0,
        last_attempt_at INTEGER,
        error_message TEXT,
        server_file_name TEXT,
        server_file_url TEXT,
        created_at INTEGER NOT NULL
      )
    ''');

    // Pre-existing row (only parent-level attaches existed pre-fix).
    await db.insert('pending_attachments', {
      'parent_uuid': 'p-1',
      'parent_doctype': 'Survey',
      'parent_fieldname': 'photo',
      'local_path': '/tmp/x.jpg',
      'state': 'pending',
      'created_at': 1,
    });

    // Apply v4 → v5 migration (function under test — see Step 2.2).
    await applyV4ToV5(db);

    final cols = await db.rawQuery(
      "PRAGMA table_info('pending_attachments')",
    );
    final names = cols.map((r) => r['name'] as String).toSet();
    expect(names.contains('top_parent_uuid'), isTrue);
    expect(names.contains('top_parent_doctype'), isTrue);

    final indexes = await db.rawQuery(
      "PRAGMA index_list('pending_attachments')",
    );
    expect(
      indexes.any((r) => r['name'] == 'ix_attach_top_parent'),
      isTrue,
    );

    // Backfill: existing row has top_parent_* equal to its parent_*.
    final rows = await db.query('pending_attachments');
    expect(rows.first['top_parent_uuid'], 'p-1');
    expect(rows.first['top_parent_doctype'], 'Survey');

    await db.close();
  });
}

// Imported in Step 2.2.
Future<void> applyV4ToV5(Database db) async {
  throw UnimplementedError();
}
```

- [ ] **Step 2.2: Run test, verify it fails on UnimplementedError**

Run: `cd /home/omprakash/Desktop/snf/frappe-mobile-sdk && flutter test test/database/migrations/v4_to_v5_test.dart`

Expected: FAIL with `UnimplementedError`.

- [ ] **Step 2.3: Implement the migration helper + wire it into `_onUpgrade`**

Edit `lib/src/database/app_database.dart`:

1. Change line 13:

```dart
  static const int _version = 5;
```

2. Append a new branch to `_onUpgrade` after the existing `if (oldVersion < 4)` block (after line 157):

```dart
    if (oldVersion < 5) {
      await applyV4ToV5(db);
    }
```

3. Add the following at the bottom of the file (a top-level function, OUTSIDE the class) — production migration AND the test exercise the same code:

```dart
/// Applied as part of `_onUpgrade(oldVersion < 5)`. Exposed at top level
/// so the migration test can run it directly against an in-memory DB
/// shaped like the v4 schema.
///
/// Adds `top_parent_uuid` + `top_parent_doctype` to `pending_attachments`
/// (nullable; DAO enforces non-null at insert). Backfills pre-existing
/// rows from `parent_uuid` / `parent_doctype` — pre-fix only parent-level
/// attaches existed because attach_field.dart never wired `dao.enqueue`.
Future<void> applyV4ToV5(Database db) async {
  const stmts = <String>[
    'ALTER TABLE pending_attachments ADD COLUMN top_parent_uuid TEXT',
    'ALTER TABLE pending_attachments ADD COLUMN top_parent_doctype TEXT',
    'CREATE INDEX IF NOT EXISTS ix_attach_top_parent '
        'ON pending_attachments(top_parent_uuid, state)',
  ];
  for (final stmt in stmts) {
    try {
      await db.execute(stmt);
    } on DatabaseException catch (e) {
      if (!e.toString().toLowerCase().contains('duplicate column')) {
        rethrow;
      }
    }
  }
  await db.execute(
    'UPDATE pending_attachments '
    'SET top_parent_uuid = parent_uuid, '
    '    top_parent_doctype = parent_doctype '
    'WHERE top_parent_uuid IS NULL',
  );
}
```

4. In the test file from Step 2.1, replace the throwaway `applyV4ToV5` stub at the bottom with an import:

```dart
import 'package:frappe_mobile_sdk/src/database/app_database.dart'
    show applyV4ToV5;
```

- [ ] **Step 2.4: Run test, verify it passes**

Run: `cd /home/omprakash/Desktop/snf/frappe-mobile-sdk && flutter test test/database/migrations/v4_to_v5_test.dart`

Expected: PASS.

---

## Task 3: SDK PendingAttachment model

**Files:**
- Modify: `lib/src/models/pending_attachment.dart`

- [ ] **Step 3.1: Write a failing model test**

In `test/database/daos/pending_attachment_dao_test.dart`, add at the bottom:

```dart
  test('PendingAttachment.fromMap parses top_parent_uuid + top_parent_doctype',
      () async {
    final id = await dao.enqueue(
      parentDoctype: 'Survey Item',
      parentUuid: 'child-1',
      parentFieldname: 'photo',
      topParentUuid: 'survey-7',
      topParentDoctype: 'Survey',
      localPath: '/tmp/p.jpg',
    );
    final row = await dao.findById(id);
    expect(row!.parentUuid, 'child-1');
    expect(row.parentDoctype, 'Survey Item');
    expect(row.topParentUuid, 'survey-7');
    expect(row.topParentDoctype, 'Survey');
  });
```

This will fail to compile because `enqueue` does not yet accept `topParentUuid`/`topParentDoctype` (Task 4) and `PendingAttachment` does not yet expose those getters.

- [ ] **Step 3.2: Run test, verify compile failure**

Run: `cd /home/omprakash/Desktop/snf/frappe-mobile-sdk && flutter test test/database/daos/pending_attachment_dao_test.dart`

Expected: FAIL — `The named parameter 'topParentUuid' isn't defined`.

- [ ] **Step 3.3: Update the model**

Replace the entire body of `PendingAttachment` in `lib/src/models/pending_attachment.dart` with:

```dart
class PendingAttachment {
  final int id;
  final String parentUuid;
  final String parentDoctype;
  final String parentFieldname;
  final String topParentUuid;
  final String topParentDoctype;
  final String localPath;
  final String? fileName;
  final String? mimeType;
  final bool isPrivate;
  final int? sizeBytes;
  final AttachmentState state;
  final int retryCount;
  final DateTime? lastAttemptAt;
  final String? errorMessage;
  final String? serverFileName;
  final String? serverFileUrl;
  final DateTime createdAt;

  PendingAttachment({
    required this.id,
    required this.parentUuid,
    required this.parentDoctype,
    required this.parentFieldname,
    required this.topParentUuid,
    required this.topParentDoctype,
    required this.localPath,
    this.fileName,
    this.mimeType,
    required this.isPrivate,
    this.sizeBytes,
    required this.state,
    required this.retryCount,
    this.lastAttemptAt,
    this.errorMessage,
    this.serverFileName,
    this.serverFileUrl,
    required this.createdAt,
  });

  factory PendingAttachment.fromMap(Map<String, Object?> row) {
    return PendingAttachment(
      id: row['id'] as int,
      parentUuid: row['parent_uuid'] as String,
      parentDoctype: row['parent_doctype'] as String,
      parentFieldname: row['parent_fieldname'] as String,
      topParentUuid: row['top_parent_uuid'] as String,
      topParentDoctype: row['top_parent_doctype'] as String,
      localPath: row['local_path'] as String,
      fileName: row['file_name'] as String?,
      mimeType: row['mime_type'] as String?,
      isPrivate: (row['is_private'] as int? ?? 1) == 1,
      sizeBytes: row['size_bytes'] as int?,
      state: AttachmentStateHelpers.parse(row['state'] as String),
      retryCount: (row['retry_count'] as int?) ?? 0,
      lastAttemptAt: row['last_attempt_at'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              row['last_attempt_at'] as int,
              isUtc: true,
            ),
      errorMessage: row['error_message'] as String?,
      serverFileName: row['server_file_name'] as String?,
      serverFileUrl: row['server_file_url'] as String?,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        row['created_at'] as int,
        isUtc: true,
      ),
    );
  }
}
```

The model still won't compile end-to-end because the DAO's `enqueue` still has the old signature. Task 4 fixes that.

---

## Task 4: SDK DAO — required top_parent_* params + child discovery query

**Files:**
- Modify: `lib/src/database/daos/pending_attachment_dao.dart`
- Modify: `test/database/daos/pending_attachment_dao_test.dart` (existing call sites)

- [ ] **Step 4.1: Write a failing test for findPendingForTopParent**

Add to `test/database/daos/pending_attachment_dao_test.dart`:

```dart
  test('findPendingForTopParent finds attachments queued against parent '
      'AND against children of that parent', () async {
    // Parent-level attachment.
    final aParent = await dao.enqueue(
      parentDoctype: 'Survey',
      parentUuid: 'survey-1',
      parentFieldname: 'cover',
      topParentUuid: 'survey-1',
      topParentDoctype: 'Survey',
      localPath: '/tmp/cover.jpg',
    );
    // Child-row attachment under the same parent.
    final aChild = await dao.enqueue(
      parentDoctype: 'Survey Item',
      parentUuid: 'item-1',
      parentFieldname: 'photo',
      topParentUuid: 'survey-1',
      topParentDoctype: 'Survey',
      localPath: '/tmp/item.jpg',
    );
    // Unrelated parent (negative control).
    await dao.enqueue(
      parentDoctype: 'Survey',
      parentUuid: 'survey-2',
      parentFieldname: 'cover',
      topParentUuid: 'survey-2',
      topParentDoctype: 'Survey',
      localPath: '/tmp/other.jpg',
    );

    final rows = await dao.findPendingForTopParent('survey-1');
    final ids = rows.map((r) => r.id).toSet();
    expect(ids, {aParent, aChild});
  });
```

- [ ] **Step 4.2: Run test, verify compile failure**

Run: `cd /home/omprakash/Desktop/snf/frappe-mobile-sdk && flutter test test/database/daos/pending_attachment_dao_test.dart`

Expected: FAIL — `The method 'findPendingForTopParent' isn't defined`.

- [ ] **Step 4.3: Update the DAO**

Replace the body of `lib/src/database/daos/pending_attachment_dao.dart` with:

```dart
import 'package:sqflite/sqflite.dart';
import '../../models/pending_attachment.dart';

class PendingAttachmentDao {
  final DatabaseExecutor _db;

  PendingAttachmentDao(this._db);

  Future<int> enqueue({
    required String parentDoctype,
    required String parentUuid,
    required String parentFieldname,
    required String topParentUuid,
    required String topParentDoctype,
    required String localPath,
    String? fileName,
    String? mimeType,
    bool isPrivate = true,
    int? sizeBytes,
  }) async {
    return _db.insert('pending_attachments', <String, Object?>{
      'parent_doctype': parentDoctype,
      'parent_uuid': parentUuid,
      'parent_fieldname': parentFieldname,
      'top_parent_uuid': topParentUuid,
      'top_parent_doctype': topParentDoctype,
      'local_path': localPath,
      'file_name': fileName,
      'mime_type': mimeType,
      'is_private': isPrivate ? 1 : 0,
      'size_bytes': sizeBytes,
      'state': AttachmentState.pending.wireName,
      'retry_count': 0,
      'created_at': DateTime.now().toUtc().millisecondsSinceEpoch,
    });
  }

  Future<PendingAttachment?> findById(int id) async {
    final rows = await _db.query(
      'pending_attachments',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return PendingAttachment.fromMap(rows.first);
  }

  /// Finds all pending/uploading attachments queued against [topParentUuid]
  /// — that is, queued for the outbox row whose mobile_uuid is
  /// [topParentUuid]. Includes attachments queued against child-row
  /// uuids whose `top_parent_uuid` was set to the parent's uuid by the
  /// caller at enqueue time.
  Future<List<PendingAttachment>> findPendingForTopParent(
    String topParentUuid,
  ) async {
    final rows = await _db.query(
      'pending_attachments',
      where: 'top_parent_uuid = ? AND state IN (?, ?)',
      whereArgs: [
        topParentUuid,
        AttachmentState.pending.wireName,
        AttachmentState.uploading.wireName,
      ],
      orderBy: 'created_at ASC',
    );
    return rows.map(PendingAttachment.fromMap).toList();
  }

  Future<void> markUploading(int id) async {
    await _db.update(
      'pending_attachments',
      <String, Object?>{
        'state': AttachmentState.uploading.wireName,
        'last_attempt_at': DateTime.now().toUtc().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> markDone(
    int id, {
    required String serverFileName,
    required String serverFileUrl,
  }) async {
    await _db.update(
      'pending_attachments',
      <String, Object?>{
        'state': AttachmentState.done.wireName,
        'server_file_name': serverFileName,
        'server_file_url': serverFileUrl,
        'last_attempt_at': DateTime.now().toUtc().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> markFailed(int id, {required String errorMessage}) async {
    await _db.rawUpdate(
      '''
      UPDATE pending_attachments
        SET state = ?, error_message = ?,
            retry_count = retry_count + 1,
            last_attempt_at = ?
        WHERE id = ?
      ''',
      [
        AttachmentState.failed.wireName,
        errorMessage,
        DateTime.now().toUtc().millisecondsSinceEpoch,
        id,
      ],
    );
  }
}
```

The old `findPendingForParent(parentUuid)` is intentionally removed: every existing caller is in tests, and the production caller (the pipeline) will use `findPendingForTopParent`.

- [ ] **Step 4.4: Update existing DAO tests to pass the new required params**

In `test/database/daos/pending_attachment_dao_test.dart`, update the existing `enqueue` call sites at lines 27, 42, 46, 56, 70 to add `topParentUuid` + `topParentDoctype`. For tests that previously called `findPendingForParent('p1')`, change them to `findPendingForTopParent('p1')` AND set `topParentUuid: 'p1'` on the relevant `enqueue` calls.

Concretely, the 'findPendingForParent returns matching rows' test (around line 41) becomes:

```dart
  test('findPendingForTopParent returns matching rows', () async {
    await dao.enqueue(
      parentDoctype: 'O', parentUuid: 'p1', parentFieldname: 'a',
      topParentUuid: 'p1', topParentDoctype: 'O',
      localPath: '/x.jpg',
    );
    await dao.enqueue(
      parentDoctype: 'O', parentUuid: 'p2', parentFieldname: 'a',
      topParentUuid: 'p2', topParentDoctype: 'O',
      localPath: '/y.jpg',
    );
    final rows = await dao.findPendingForTopParent('p1');
    expect(rows, hasLength(1));
    expect(rows.first.parentUuid, 'p1');
  });
```

For the simple tests at lines 27, 56, 70 (enqueue / state transitions), set `topParentUuid: parentUuid, topParentDoctype: parentDoctype` so the existing semantics (parent-level attachment) are preserved.

- [ ] **Step 4.5: Run all DAO tests, verify pass**

Run: `cd /home/omprakash/Desktop/snf/frappe-mobile-sdk && flutter test test/database/daos/pending_attachment_dao_test.dart`

Expected: ALL PASS.

---

## Task 5: SDK AttachmentPipeline — drop sentinel, rename to top-parent

**Files:**
- Modify: `lib/src/sync/attachment_pipeline.dart`
- Modify: `test/sync/attachment_pipeline_test.dart`

- [ ] **Step 5.1: Write a failing test that asserts no docname is sent**

In `test/sync/attachment_pipeline_test.dart`, add a new test (above the existing `'uploads pending files'` test, after `tearDown`):

```dart
  test('uploads with dt=parent_doctype but NO docname (no sentinel)',
      () async {
    String? capturedDoctype;
    String? capturedDocname;

    await dao.enqueue(
      parentDoctype: 'Survey',
      parentUuid: 'survey-1',
      parentFieldname: 'cover',
      topParentUuid: 'survey-1',
      topParentDoctype: 'Survey',
      localPath: '/tmp/cover.jpg',
    );

    final pipeline = AttachmentPipeline(
      dao: dao,
      uploader: (file, {doctype, docname, isPrivate = true, fileName}) async {
        capturedDoctype = doctype;
        capturedDocname = docname;
        return {'name': 'FILE-1', 'file_url': '/private/files/cover.jpg'};
      },
      backoff: const [Duration.zero, Duration.zero, Duration.zero],
      fileFromPath: (p) => _FakeFile(p),
    );

    await pipeline.uploadPendingForTopParent('survey-1');

    expect(capturedDoctype, 'Survey');
    expect(capturedDocname, isNull,
        reason:
            'docname must be null — uploading with a sentinel like '
            '"new-survey" creates orphaned File rows that '
            'attach_files_to_document cannot relink.');
  });
```

This will fail in two ways: `uploadPendingForTopParent` doesn't exist yet, and the existing `_uploadOne` still sends a docname.

- [ ] **Step 5.2: Run test, verify failure**

Run: `cd /home/omprakash/Desktop/snf/frappe-mobile-sdk && flutter test test/sync/attachment_pipeline_test.dart`

Expected: FAIL — `'uploadPendingForTopParent' isn't defined` (compile error).

- [ ] **Step 5.3: Update the pipeline**

Edit `lib/src/sync/attachment_pipeline.dart`:

1. Rename `uploadPendingFor` → `uploadPendingForTopParent`. Update the dartdoc above it to reference §5.3 of the offline-first spec and to call out the v16 stock relinker on parent docs + the mobile_control hook on child rows.

2. In `_uploadOne` (lines 70-104), drop the `docname:` argument entirely from the `uploader(...)` call:

```dart
  Future<AttachmentUploadResult> _uploadOne(PendingAttachment p) async {
    await dao.markUploading(p.id);
    Object? lastError;
    for (var attempt = 0; attempt < backoff.length; attempt++) {
      try {
        // No `docname` — File row is created with attached_to_doctype set
        // (permission scoping) but attached_to_name=NULL. The mobile_control
        // catch-all hook on `*.on_update` (and v16 stock for parent docs)
        // relinks it to the doc/child row by file_url after the parent
        // INSERT/UPDATE commits. Spec §5.3.
        final resp = await uploader(
          fileFromPath(p.localPath),
          doctype: p.parentDoctype,
          fileName: p.fileName,
          isPrivate: p.isPrivate,
        );
        final fileUrl = resp['file_url'] as String;
        final fileName = resp['name'] as String? ?? fileUrl;
        await dao.markDone(
          p.id,
          serverFileName: fileName,
          serverFileUrl: fileUrl,
        );
        return AttachmentUploadResult(fileName: fileName, fileUrl: fileUrl);
      } catch (e) {
        lastError = e;
        if (attempt < backoff.length - 1) {
          await Future<void>.delayed(backoff[attempt + 1]);
        }
      }
    }
    await dao.markFailed(p.id, errorMessage: '$lastError');
    throw BlockedByUpstream(
      field: p.parentFieldname,
      targetDoctype: 'File',
      targetUuid: '${p.id}',
    );
  }
```

3. Replace the renamed method body so it queries by top-parent:

```dart
  /// Uploads every pending attachment for [topParentUuid] (the outbox
  /// row's mobile_uuid). Includes attachments queued against child-row
  /// uuids whose `top_parent_uuid` was set to [topParentUuid] at enqueue.
  /// Returns a map of `pending_attachments.id` → upload result.
  Future<Map<int, AttachmentUploadResult>> uploadPendingForTopParent(
    String topParentUuid,
  ) async {
    final pending = await dao.findPendingForTopParent(topParentUuid);
    final results = <int, AttachmentUploadResult>{};
    for (final p in pending) {
      results[p.id] = await _uploadOne(p);
    }
    return results;
  }
```

- [ ] **Step 5.4: Update the existing pipeline tests for the rename**

In `test/sync/attachment_pipeline_test.dart`:
- Replace `pipeline.uploadPendingFor('P')` (lines 64, 89) with `pipeline.uploadPendingForTopParent('P')`.
- For the existing `dao.enqueue` calls at lines 38, 44, 71 add `topParentUuid: 'P', topParentDoctype: 'O'` so they are queued against the same top-parent.

- [ ] **Step 5.5: Run pipeline tests, verify all pass**

Run: `cd /home/omprakash/Desktop/snf/frappe-mobile-sdk && flutter test test/sync/attachment_pipeline_test.dart`

Expected: ALL PASS, including the new "no sentinel docname" test.

---

## Task 6: SDK push_engine — adopt new method name

**Files:**
- Modify: `lib/src/sync/push_engine.dart` (line 233)

- [ ] **Step 6.1: Update the call site**

At `lib/src/sync/push_engine.dart:233`, replace:

```dart
    final uploaded = await attachments.uploadPendingFor(row.mobileUuid);
```

with:

```dart
    final uploaded = await attachments.uploadPendingForTopParent(row.mobileUuid);
```

`row.mobileUuid` is by definition the outbox row's mobile_uuid — which is exactly the `top_parent_uuid` for any attachment queued against that row OR any of its child rows.

- [ ] **Step 6.2: Run the full SDK suite**

Run: `cd /home/omprakash/Desktop/snf/frappe-mobile-sdk && flutter test`

Expected: ALL PASS. If any other tests still reference `uploadPendingFor` or call `enqueue` with the old signature, fix them in this step (search-and-replace) — they belong to the same logical refactor and shouldn't ship in a half-done state.

- [ ] **Step 6.3: Add the child-discovery integration test**

Create `test/sync/attachment_pipeline_child_discovery_test.dart`:

```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/daos/pending_attachment_dao.dart';
import 'package:frappe_mobile_sdk/src/database/schema/system_tables.dart';
import 'package:frappe_mobile_sdk/src/sync/attachment_pipeline.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakeFile implements File {
  @override
  final String path;
  _FakeFile(this.path);
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('uploadPendingForTopParent uploads BOTH parent-field and '
      'child-row attachments belonging to the same outbox row', () async {
    final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    for (final s in systemTablesDDL()) {
      await db.execute(s);
    }
    final dao = PendingAttachmentDao(db);

    await dao.enqueue(
      parentDoctype: 'Survey',
      parentUuid: 'survey-1',
      parentFieldname: 'cover',
      topParentUuid: 'survey-1',
      topParentDoctype: 'Survey',
      localPath: '/tmp/cover.jpg',
    );
    await dao.enqueue(
      parentDoctype: 'Survey Item',
      parentUuid: 'item-1', // child-row uuid (different from top parent)
      parentFieldname: 'photo',
      topParentUuid: 'survey-1',
      topParentDoctype: 'Survey',
      localPath: '/tmp/item-1.jpg',
    );

    final captured = <String>[];
    final pipeline = AttachmentPipeline(
      dao: dao,
      uploader: (file, {doctype, docname, isPrivate = true, fileName}) async {
        captured.add('${file.path}|$doctype');
        return {
          'name': 'FILE-${file.path}',
          'file_url': '/private/files${file.path}',
        };
      },
      backoff: const [Duration.zero, Duration.zero, Duration.zero],
      fileFromPath: (p) => _FakeFile(p),
    );

    final result = await pipeline.uploadPendingForTopParent('survey-1');

    expect(result, hasLength(2));
    expect(captured, containsAll([
      '/tmp/cover.jpg|Survey',
      '/tmp/item-1.jpg|Survey Item',
    ]));

    await db.close();
  });
}
```

- [ ] **Step 6.4: Run the new test**

Run: `cd /home/omprakash/Desktop/snf/frappe-mobile-sdk && flutter test test/sync/attachment_pipeline_child_discovery_test.dart`

Expected: PASS. The child-row attachment is discovered via `top_parent_uuid` — fixing the silent miss in today's `findPendingForParent(row.mobileUuid)` path.

---

## Task 7: mobile_control catch-all relink hook

**Files:**
- Create: `apps/mobile_control/mobile_control/attachment_relink.py`
- Modify: `apps/mobile_control/mobile_control/hooks.py`

- [ ] **Step 7.1: Implement the relink helper**

Create `apps/mobile_control/mobile_control/attachment_relink.py`:

```python
"""Mobile attachment relink hook.

The SDK uploads pending attachments BEFORE the parent INSERT/UPDATE so that
the parent payload can carry the resolved file_url. Each upload is sent
with `dt=<owning_doctype>` and NO `dn`, producing a File row with
`attached_to_doctype` set (permission-scoped to the owning doctype) but
`attached_to_name=NULL`.

After the parent doc is saved, this hook walks the parent + its child
tables. For each Attach/Attach Image field that holds a `/files` or
`/private/files` URL, it finds the unattached File row by
`(file_url, attached_to_doctype, attached_to_name IS NULL)` and rewires
`attached_to_name` (and `attached_to_field`) to the actual saved doc/child
row. This works for INSERT and UPDATE flows (registered on `on_update`)
and for submitted-doc updates (`on_update_after_submit`).

Why this hook exists for child rows specifically: in Frappe v16 child rows
are saved via raw `db_update()` (frappe/model/document.py:613-648), which
does NOT fire the document lifecycle hooks. Frappe's stock
`attach_files_to_document` therefore never runs on a child row, so the
`__temporary_name` / unattached-File logic in core never reaches them.
This hook fills that gap by walking the parent's child tables explicitly.

Why this hook also covers the parent: stock `attach_files_to_document`
matches files where ALL of attached_to_doctype/name/field are NULL. SDK
uploads have `attached_to_doctype` set (permission scoping). Different
match set, no overlap with stock.
"""

from __future__ import annotations

import frappe


_ATTACH_FIELDTYPES = ("Attach", "Attach Image")
_FILE_URL_PREFIXES = ("/files", "/private/files")


def relink_mobile_files(doc, method=None):
    """Catch-all `on_update` / `on_update_after_submit` hook.

    Fast-exits when the doc has no `mobile_uuid` (i.e. not a mobile-sync
    doctype). The check is one attribute lookup; the hook is registered
    on `*` so it fires on every save site-wide and the fast-exit is the
    cost paid by non-mobile saves.
    """
    if not getattr(doc, "mobile_uuid", None):
        return

    _relink_attach_fields(doc)

    for tf in doc.meta.get_table_fields():
        for child in (doc.get(tf.fieldname) or []):
            _relink_attach_fields(child)


def _relink_attach_fields(target):
    """For each Attach/Attach Image field on `target`, rewire the
    matching unattached File row to point at `target.name`.

    `target` is a Frappe Document — either the saved parent or one of
    its child rows. Both expose `.meta`, `.doctype`, `.name`, and
    `.get(fieldname)`.
    """
    for df in target.meta.get(
        "fields", {"fieldtype": ["in", list(_ATTACH_FIELDTYPES)]}
    ):
        value = target.get(df.fieldname) or ""
        if not value.startswith(_FILE_URL_PREFIXES):
            continue

        # Skip if already correctly linked (UPDATE re-saves, idempotency).
        if frappe.db.exists(
            "File",
            {
                "file_url": value,
                "attached_to_doctype": target.doctype,
                "attached_to_name": target.name,
                "attached_to_field": df.fieldname,
            },
        ):
            continue

        # Find the unattached File row uploaded by the SDK earlier in
        # this push. Match by (file_url, doctype, attached_to_name IS
        # NULL). When two child rows share the same file_url (content
        # dedup), each iteration consumes one row at a time — the next
        # iteration's `is None` filter no longer matches the row we
        # just linked.
        unattached = frappe.db.get_value(
            "File",
            {
                "file_url": value,
                "attached_to_doctype": target.doctype,
                "attached_to_name": ["is", "not set"],
            },
            "name",
            order_by="creation asc",
        )
        if not unattached:
            continue

        frappe.db.set_value(
            "File",
            unattached,
            {
                "attached_to_name": target.name,
                "attached_to_field": df.fieldname,
            },
        )
```

Notes on the Frappe filter syntax: `["is", "not set"]` is Frappe's idiomatic way to match `IS NULL` in `frappe.db.get_value` filters. If the version under test rejects that form, fall back to:

```python
unattached = frappe.db.sql(
    """
    SELECT name FROM `tabFile`
    WHERE file_url = %(file_url)s
      AND attached_to_doctype = %(dt)s
      AND (attached_to_name IS NULL OR attached_to_name = '')
    ORDER BY creation ASC
    LIMIT 1
    """,
    {"file_url": value, "dt": target.doctype},
)
unattached = unattached[0][0] if unattached else None
```

- [ ] **Step 7.2: Register the hook**

Edit `apps/mobile_control/mobile_control/hooks.py`. The file already has a `doc_events` dict at lines 147-159 with three doctype-scoped entries (`DocType`, `Custom Field`, `Property Setter`) — there is no `*` (catch-all) entry yet. Add a `*` key at the top of the existing dict so the result looks like this:

```python
doc_events = {
    # Mobile attachment relink — runs on every doc save site-wide; fast-
    # exits in O(1) when the doc has no `mobile_uuid` (not a mobile-sync
    # doctype). Walks the parent + child tables and rewires SDK-uploaded
    # File rows (uploaded with dt=<doctype>, dn=NULL) to point at their
    # real (doctype, name) once the parent INSERT/UPDATE commits.
    "*": {
        "on_update": "mobile_control.attachment_relink.relink_mobile_files",
        "on_update_after_submit": (
            "mobile_control.attachment_relink.relink_mobile_files"
        ),
    },
    "DocType": {
        "on_update": "mobile_control.mobile_control.doctype.mobile_configuration.mobile_configuration.update_doctype_meta_modified",
    },
    "Custom Field": {
        "on_update": "mobile_control.mobile_control.doctype.mobile_configuration.mobile_configuration.update_doctype_meta_modified",
        "on_trash": "mobile_control.mobile_control.doctype.mobile_configuration.mobile_configuration.update_doctype_meta_modified",
    },
    "Property Setter": {
        "on_update": "mobile_control.mobile_control.doctype.mobile_configuration.mobile_configuration.update_doctype_meta_modified",
        "on_trash": "mobile_control.mobile_control.doctype.mobile_configuration.mobile_configuration.update_doctype_meta_modified",
    },
}
```

The `*` and per-doctype entries coexist — Frappe merges both for any save (the catch-all and the doctype-specific list both fire). Stock Frappe's `attach_files_to_document` is also registered on `*.on_update` in `apps/frappe/frappe/hooks.py:155-166`; our hook coexists with it because the two match disjoint File-row sets (stock requires all `attached_to_*` to be NULL; ours requires `attached_to_doctype` set).

- [ ] **Step 7.3: Manual end-to-end verification — parent attachment**

This step is manual because mobile_control does not have a test harness set up in this repo. Run from a bench shell:

```
bench --site <site> migrate
bench --site <site> console
```

In the console:

```python
import frappe
from frappe.utils.file_manager import save_file_on_filesystem
from io import BytesIO

# 1. Simulate an SDK upload: File with attached_to_doctype set, no name.
f = frappe.get_doc({
    "doctype": "File",
    "file_name": "smoke.txt",
    "content": b"hello",
    "is_private": 1,
    "attached_to_doctype": "ToDo",  # any synced doctype
}).insert(ignore_permissions=True)
print("uploaded file:", f.name, "attached_to_name:", f.attached_to_name)
file_url = f.file_url

# 2. Create a ToDo with mobile_uuid set, file_url in an Attach field
#    that exists on ToDo (or use a synced doctype that DOES have one).
#    The point is: doc has mobile_uuid → hook fires → File should relink.
todo = frappe.get_doc({
    "doctype": "ToDo",
    "description": "smoke",
    "mobile_uuid": "smoke-uuid-1",
    # If ToDo doesn't have an Attach field in your site, swap to
    # whatever doctype IS registered in Mobile Configuration.
}).insert(ignore_permissions=True)
print("saved doc:", todo.name)

# 3. Inspect: File should now have attached_to_name set to todo.name IF
#    the doc had an Attach field carrying file_url. (For a doc with no
#    Attach field, the hook will be a no-op; pick a synced doctype that
#    has one for this smoke check.)
f.reload()
print("File after relink:", f.attached_to_name, f.attached_to_field)
```

Expected: for a doctype with an `Attach` field set to `file_url` AND `mobile_uuid` populated, the File row's `attached_to_name` matches `todo.name` after insert. If `attached_to_name` stays NULL, the hook didn't fire — verify registration from the same console with `print(frappe.get_hooks("doc_events").get("*", {}))` and confirm `relink_mobile_files` appears under `on_update`. If it does, the field value probably didn't start with `/files` or `/private/files` (the helper bails on URLs that don't).

- [ ] **Step 7.4: Manual end-to-end verification — child-row attachment**

In the same bench console, against a synced doctype that has a child table containing an Attach field (use one from the registered `Mobile Configuration.table_lwis` for your site):

```python
import frappe

# 1. Upload File for a child row.
child_file = frappe.get_doc({
    "doctype": "File",
    "file_name": "child.txt",
    "content": b"child",
    "is_private": 1,
    "attached_to_doctype": "<Child Doctype>",  # actual child doctype
}).insert(ignore_permissions=True)
url = child_file.file_url

# 2. Insert parent with one child row carrying that file_url.
parent = frappe.get_doc({
    "doctype": "<Parent Doctype>",
    "mobile_uuid": "smoke-parent-1",
    "<child_table_field>": [
        {"<attach_field_on_child>": url, "mobile_uuid": "smoke-child-1"},
    ],
}).insert(ignore_permissions=True)

# 3. Verify the File now points at the CHILD row's name (not the parent).
child_file.reload()
print("attached_to_name:", child_file.attached_to_name)
print("attached_to_doctype:", child_file.attached_to_doctype)
print("attached_to_field:", child_file.attached_to_field)
expected_child_name = parent.get("<child_table_field>")[0].name
assert child_file.attached_to_name == expected_child_name, (
    f"expected {expected_child_name}, got {child_file.attached_to_name}"
)
print("OK — child relink works.")
```

Expected: `attached_to_name` equals the auto-generated child row name (e.g., `abc123def`), `attached_to_field` is the Attach field on the child doctype.

If this fails, common causes:
- `mobile_uuid` field missing on the child doctype meta. mobile_control's `_ensure_mobile_uuid_field` only runs for top-level doctypes registered in `MobileConfiguration.table_lwis`. The hook's fast-exit `if not getattr(doc, "mobile_uuid", None): return` only applies to the parent (`doc`), not children — children are walked unconditionally once the parent has `mobile_uuid`. But if `target.meta.get("fields", ...)` for the child returns no Attach fields (e.g., schema mismatch), the loop is a no-op. Verify with `frappe.get_meta("<Child Doctype>").get("fields", {"fieldtype": ["in", ["Attach", "Attach Image"]]})`.

---

## Self-Review

Spec coverage walk-through against the design discussion of 2026-05-01:

1. ✅ "Stop using `new-<doctype>` sentinel" — Task 5.3 removes `docname` from the upload call.
2. ✅ "Discover all attachments for one outbox row including child-row attachments" — Task 1 adds the column, Task 4 adds the query, Task 6 wires the push engine, Task 6.3 verifies end-to-end.
3. ✅ "Catch-all hook on `*.on_update` with mobile_uuid fast-exit" — Task 7.1 (helper) and 7.2 (registration). `on_update_after_submit` also covered.
4. ✅ "Walk child tables explicitly because v16 child rows skip lifecycle hooks" — Task 7.1 has the `for tf in doc.meta.get_table_fields()` walk.
5. ✅ "Permission scoping on upload" — Task 5.3 keeps `dt=parent_doctype` (so `frappe/handler.py:161` runs `check_write_permission`).
6. ✅ "v16 content_hash dedup is OK because it shares disk blob, not File row" — design relies on this; no code path required.
7. ✅ "No new server doctype, no custom field on `File`" — Task 7 adds neither.
8. ✅ "Cleanup of orphan File rows" — Frappe's existing `cleanup_unattached_files` cron is left untouched; no new cron added (per design discussion: an unresolved File row that never relinks will be reaped by Frappe's own retention logic, no mobile-specific cleanup needed in v1).

Out of scope for this plan (called out for completeness, not implemented here):
- Extending `_ensure_mobile_uuid_field` to inject `mobile_uuid` transitively into child doctypes. Not needed for THIS fix because the hook's fast-exit checks the parent's `mobile_uuid`, not the child's. Needed separately for Spec §5.7 INSERT idempotency on child rows.
- UI wiring of `attach_field.dart` to call `dao.enqueue`. The pipeline is plumbing today; UI wiring is its own follow-up.
- `attach_idx` for hypothetical multi-slot-per-field. Frappe Attach fields are single-valued in v16; revisit only if Frappe ever changes that.

Placeholder scan: no `TBD`, no `add appropriate error handling`, no `similar to Task N`, no undefined types. Method signatures consistent across tasks (`uploadPendingForTopParent`, `findPendingForTopParent`, `relink_mobile_files`, `_relink_attach_fields`).

Type consistency: `topParentUuid` / `topParentDoctype` named identically across model (Task 3), DAO (Task 4), and pipeline tests (Task 5, 6.3). `top_parent_uuid` / `top_parent_doctype` named identically across schema (Task 1), migration (Task 2), and DAO SQL (Task 4). `relink_mobile_files` referenced consistently in `attachment_relink.py` (Task 7.1) and `hooks.py` (Task 7.2).
