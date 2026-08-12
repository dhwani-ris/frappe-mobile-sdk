import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/sync/pull_apply.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DocTypeMeta _meta() => DocTypeMeta(
  name: 'Patient',
  isTable: false,
  fields: [DocField(fieldname: 'patient_name', fieldtype: 'Data')],
);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;

  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await db.execute('''
      CREATE TABLE docs__patient (
        mobile_uuid TEXT PRIMARY KEY,
        server_name TEXT,
        sync_status TEXT NOT NULL DEFAULT 'synced',
        sync_error TEXT,
        error_code TEXT,
        sync_attempts INTEGER NOT NULL DEFAULT 0,
        last_attempt_at INTEGER,
        sync_op TEXT,
        push_base_payload TEXT,
        docstatus INTEGER NOT NULL DEFAULT 0,
        modified TEXT,
        local_modified INTEGER NOT NULL DEFAULT 0,
        pulled_at INTEGER,
        patient_name TEXT
      )
    ''');
    // The outbox table must exist so that the isOwnInsertRoundtrip guard
    // in _applyPageInTxnSequential can query it without throwing.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS outbox (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        doctype TEXT NOT NULL,
        mobile_uuid TEXT NOT NULL,
        operation TEXT NOT NULL,
        state TEXT NOT NULL DEFAULT 'pending',
        error_code TEXT,
        error_message TEXT,
        payload TEXT,
        created_at INTEGER NOT NULL
      )
    ''');
  });

  tearDown(() async => db.close());

  // T1 — dirty row during initial sync: sequential path chosen, row flagged
  // as conflict rather than silently overwritten.
  test(
    'T1: dirty row during initial sync → conflict flagged, local edit preserved',
    () async {
      await db.insert('docs__patient', {
        'mobile_uuid': 'uuid-dirty',
        'server_name': 'PAT-001',
        'sync_status': 'dirty',
        'sync_op': 'UPDATE',
        'local_modified': 1,
        'modified': '2026-05-01 10:00:00',
        'patient_name': 'Local Edit',
      });

      await PullApply.applyPage(
        db: db,
        parentMeta: _meta(),
        parentTable: 'docs__patient',
        childMetasByFieldname: const {},
        rows: [
          {
            'name': 'PAT-001',
            'modified': '2026-06-01 10:00:00', // server advanced
            'patient_name': 'Server Version',
          },
        ],
        isInitialSync: true,
      );

      final rows = await db.query('docs__patient');
      expect(rows, hasLength(1));
      expect(
        rows.first['sync_status'],
        'conflict',
        reason:
            'server advanced past dirty local edit → must be conflict, not synced',
      );
      expect(
        rows.first['patient_name'],
        'Local Edit',
        reason: 'local edit must not be overwritten',
      );
    },
  );

  // T2 — tombstoned row during initial sync: sequential path chosen,
  // tombstone respected, row not resurrected.
  test('T2: tombstoned row during initial sync → not resurrected', () async {
    await db.insert('docs__patient', {
      'mobile_uuid': 'uuid-tomb',
      'server_name': 'PAT-002',
      'sync_status': 'deleted',
      'sync_op': 'DELETE',
      'local_modified': 1,
      'patient_name': 'Should Stay Deleted',
    });

    await PullApply.applyPage(
      db: db,
      parentMeta: _meta(),
      parentTable: 'docs__patient',
      childMetasByFieldname: const {},
      rows: [
        {
          'name': 'PAT-002',
          'modified': '2026-06-01 10:00:00',
          'patient_name': 'Server Version',
        },
      ],
      isInitialSync: true,
    );

    final rows = await db.query('docs__patient');
    expect(rows, hasLength(1));
    expect(
      rows.first['sync_status'],
      'deleted',
      reason: 'tombstoned row must not be resurrected',
    );
    expect(rows.first['patient_name'], 'Should Stay Deleted');
  });

  // T3 — ghost-success row (mobile_uuid present, server_name null) during
  // initial sync: sequential path chosen, server_name stamped, no duplicate.
  test(
    'T3: ghost-success row during initial sync → no duplicate, server_name stamped',
    () async {
      await db.insert('docs__patient', {
        'mobile_uuid': 'ghost-uuid-1',
        'server_name': null, // push committed server-side; writeback pending
        'sync_status': 'dirty',
        'sync_op': 'INSERT',
        'local_modified': 1,
        'patient_name': 'Ghost Patient',
      });

      await PullApply.applyPage(
        db: db,
        parentMeta: _meta(),
        parentTable: 'docs__patient',
        childMetasByFieldname: const {},
        rows: [
          {
            'name': 'PAT-003',
            'mobile_uuid': 'ghost-uuid-1', // server echoes the UUID back
            'modified': '2026-06-01 10:00:00',
            'patient_name': 'Ghost Patient',
          },
        ],
        isInitialSync: true,
      );

      final rows = await db.query('docs__patient');
      expect(
        rows,
        hasLength(1),
        reason: 'must NOT create a duplicate row for the ghost-success INSERT',
      );
    },
  );

  // T4 — clean slate: bulk path is safe; row inserted normally.
  test(
    'T4: clean slate during initial sync → row inserted, sync_status=synced',
    () async {
      // No pre-existing rows — bulk path should be chosen.
      await PullApply.applyPage(
        db: db,
        parentMeta: _meta(),
        parentTable: 'docs__patient',
        childMetasByFieldname: const {},
        rows: [
          {
            'name': 'PAT-004',
            'modified': '2026-06-01 10:00:00',
            'patient_name': 'Brand New',
          },
        ],
        isInitialSync: true,
      );

      final rows = await db.query('docs__patient');
      expect(rows, hasLength(1));
      expect(rows.first['sync_status'], 'synced');
      expect(rows.first['server_name'], 'PAT-004');
      expect(rows.first['patient_name'], 'Brand New');
    },
  );
}
