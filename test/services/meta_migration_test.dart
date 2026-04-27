import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/services/meta_migration.dart';
import 'package:frappe_mobile_sdk/src/database/schema/system_tables.dart';
import 'package:frappe_mobile_sdk/src/database/schema/parent_schema.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/meta_diff.dart';
import 'package:sqflite/sqflite.dart' show DatabaseException, Sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DocField f(String n, String t, {String? options}) =>
    DocField(fieldname: n, fieldtype: t, label: n, options: options);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;

  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await db.execute('''
      CREATE TABLE doctype_meta (
        doctype TEXT PRIMARY KEY,
        modified TEXT,
        serverModifiedAt TEXT,
        isMobileForm INTEGER NOT NULL DEFAULT 0,
        metaJson TEXT NOT NULL,
        groupName TEXT,
        sortOrder INTEGER
      )
    ''');
    for (final stmt in doctypeMetaExtensionsDDL()) {
      await db.execute(stmt);
    }
    for (final stmt in systemTablesDDL()) {
      await db.execute(stmt);
    }
    final meta = DocTypeMeta(name: 'Cust', fields: [f('name', 'Data')]);
    await db.insert('doctype_meta', {
      'doctype': 'Cust',
      'metaJson': '{}',
      'isMobileForm': 0,
    });
    for (final s in buildParentSchemaDDL(meta, tableName: 'docs__cust')) {
      await db.execute(s);
    }
  });

  tearDown(() async => db.close());

  test('added field → ALTER TABLE ADD COLUMN', () async {
    final diff = MetaDiff(
      doctype: 'Cust',
      addedFields: const [AddedField(name: 'age', sqlType: 'INTEGER')],
      removedFields: const [],
      typeChanged: const [],
      addedIsLocalFor: const [],
      addedNormFor: const [],
      indexesToDrop: const [],
    );
    await MetaMigration.apply(db, diff, tableName: 'docs__cust');
    final cols = await db.rawQuery('PRAGMA table_info(docs__cust)');
    expect(cols.any((r) => r['name'] == 'age'), isTrue);
  });

  test('added Link → adds both column and __is_local', () async {
    final diff = MetaDiff(
      doctype: 'Cust',
      addedFields: const [AddedField(name: 'territory', sqlType: 'TEXT')],
      removedFields: const [],
      typeChanged: const [],
      addedIsLocalFor: const ['territory'],
      addedNormFor: const [],
      indexesToDrop: const [],
    );
    await MetaMigration.apply(db, diff, tableName: 'docs__cust');
    final cols = await db.rawQuery('PRAGMA table_info(docs__cust)');
    final names = cols.map((r) => r['name']).toSet();
    expect(names, contains('territory'));
    expect(names, contains('territory__is_local'));
  });

  test('added __norm → creates column + backfills normalized value', () async {
    await db.insert('docs__cust', {
      'mobile_uuid': 'u1',
      'name': 'Café Ankıt',
      'sync_status': 'synced',
      'local_modified': 0,
    });
    final diff = MetaDiff(
      doctype: 'Cust',
      addedFields: const [],
      removedFields: const [],
      typeChanged: const [],
      addedIsLocalFor: const [],
      addedNormFor: const ['name'],
      indexesToDrop: const [],
    );
    await MetaMigration.apply(db, diff, tableName: 'docs__cust');
    final row = await db.query(
      'docs__cust',
      where: 'mobile_uuid=?',
      whereArgs: ['u1'],
    );
    expect(row.first['name__norm'], 'cafe ankit');
  });

  test('indexesToDrop — silently no-ops when missing', () async {
    final diff = MetaDiff(
      doctype: 'Cust',
      addedFields: const [],
      removedFields: const ['legacy'],
      typeChanged: const [],
      addedIsLocalFor: const [],
      addedNormFor: const [],
      indexesToDrop: const ['ix_cust_legacy', 'ix_cust_nonexistent'],
    );
    // Should not throw even though neither index exists.
    await MetaMigration.apply(db, diff, tableName: 'docs__cust');
  });

  test('__norm backfill correctly handles >1 chunk (501 rows)', () async {
    // Seed 501 rows (chunkSize=500 in MetaMigration → forces a second pass).
    final batch = db.batch();
    for (var i = 0; i < 501; i++) {
      batch.insert('docs__cust', {
        'mobile_uuid': 'u$i',
        'name': 'Café-$i',
        'sync_status': 'synced',
        'local_modified': i,
      });
    }
    await batch.commit(noResult: true);

    final diff = MetaDiff(
      doctype: 'Cust',
      addedFields: const [],
      removedFields: const [],
      typeChanged: const [],
      addedIsLocalFor: const [],
      addedNormFor: const ['name'],
      indexesToDrop: const [],
    );
    await MetaMigration.apply(db, diff, tableName: 'docs__cust');

    final cnt = Sqflite.firstIntValue(
      await db.rawQuery(
        "SELECT COUNT(*) FROM docs__cust WHERE name__norm IS NOT NULL",
      ),
    );
    expect(cnt, 501,
        reason: 'every row across the chunk boundary must be backfilled');
    final sample = await db.query(
      'docs__cust',
      where: 'mobile_uuid=?',
      whereArgs: ['u500'],
    );
    expect(sample.first['name__norm'], 'cafe-500');
  });

  test(
    '__norm backfill is idempotent — re-applying the same diff is safe',
    () async {
      await db.insert('docs__cust', {
        'mobile_uuid': 'u',
        'name': 'Café',
        'sync_status': 'synced',
        'local_modified': 0,
      });
      final diff = MetaDiff(
        doctype: 'Cust',
        addedFields: const [],
        removedFields: const [],
        typeChanged: const [],
        addedIsLocalFor: const [],
        addedNormFor: const ['name'],
        indexesToDrop: const [],
      );
      await MetaMigration.apply(db, diff, tableName: 'docs__cust');
      // Second invocation must NOT throw (column already exists) and must
      // re-normalize correctly (no duplicate-add, idempotent UPDATEs).
      await MetaMigration.apply(db, diff, tableName: 'docs__cust');
      final row = await db.query(
        'docs__cust',
        where: 'mobile_uuid=?',
        whereArgs: ['u'],
      );
      expect(row.first['name__norm'], 'cafe');
    },
  );

  test(
    'backfill failure rolls back: partial __norm updates do not persist',
    () async {
      // Force a backfill failure mid-loop and verify the transaction
      // rolls back ALL partial UPDATEs.
      //
      // Setup: pre-add `nm` + `nm__norm` columns, plus a UNIQUE index on
      // `nm__norm` so the second backfill UPDATE (which would write the
      // same normalized value as the first) throws. Then seed three rows
      // whose `nm` values all normalize to the same string.
      await db.execute('ALTER TABLE docs__cust ADD COLUMN nm TEXT');
      await db.execute('ALTER TABLE docs__cust ADD COLUMN nm__norm TEXT');
      await db.execute(
        'CREATE UNIQUE INDEX ix_force_fail ON docs__cust(nm__norm)',
      );

      // Three rows; the first two normalize identically — second UPDATE
      // hits the unique index. The third never gets touched.
      for (final spec in const [
        ['dup1', 'Café'],
        ['dup2', 'Cafe'],
        ['dup3', 'OtherValue'],
      ]) {
        await db.insert('docs__cust', {
          'mobile_uuid': spec[0],
          'nm': spec[1],
          'sync_status': 'synced',
          'local_modified': 0,
        });
      }

      final diff = MetaDiff(
        doctype: 'Cust',
        addedFields: const [],
        removedFields: const [],
        typeChanged: const [],
        addedIsLocalFor: const [],
        addedNormFor: const ['nm'], // forces backfill of `nm__norm`
        indexesToDrop: const [],
      );

      await expectLater(
        MetaMigration.apply(db, diff, tableName: 'docs__cust'),
        throwsA(isA<DatabaseException>()),
      );

      // Confirm no row retains a partially-backfilled value: rollback
      // restored pre-call state (all rows still have nm__norm = NULL).
      final filled = Sqflite.firstIntValue(
        await db.rawQuery(
          'SELECT COUNT(*) FROM docs__cust WHERE nm__norm IS NOT NULL',
        ),
      );
      expect(filled, 0,
          reason:
              'partial backfill UPDATE for "dup1" must roll back when '
              '"dup2" UPDATE violates the unique index');
    },
  );

  test('wrapped in a transaction (rollback on failure)', () async {
    // Pre-create a column so a duplicate ADD COLUMN forces failure.
    await db.execute('ALTER TABLE docs__cust ADD COLUMN pre_exists TEXT');
    final diff = MetaDiff(
      doctype: 'Cust',
      addedFields: const [
        AddedField(name: 'safe_addition', sqlType: 'TEXT'),
        // Second add reuses an existing column → SQLite throws.
        AddedField(name: 'pre_exists', sqlType: 'TEXT'),
      ],
      removedFields: const [],
      typeChanged: const [],
      addedIsLocalFor: const [],
      addedNormFor: const [],
      indexesToDrop: const [],
    );
    await expectLater(
      MetaMigration.apply(db, diff, tableName: 'docs__cust'),
      throwsA(isA<DatabaseException>()),
    );
    final cols = await db.rawQuery('PRAGMA table_info(docs__cust)');
    final names = cols.map((r) => r['name']).toSet();
    // Confirms full transaction rollback: even the earlier successful
    // `safe_addition` was undone when the second ADD COLUMN failed. (sqflite
    // wraps the block in BEGIN/ROLLBACK, and the SQLite engine handles
    // ALTER TABLE inside transactions on modern versions.)
    expect(names, isNot(contains('safe_addition')));
    expect(names, contains('pre_exists'),
        reason: 'pre-existing column must still be there');
  });
}
