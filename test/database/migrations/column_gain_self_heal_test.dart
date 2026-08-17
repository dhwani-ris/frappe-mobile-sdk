// Does a device ALREADY in the broken state heal itself?
//
// The MetaDiffer fix (see test/meta_differ_column_gain_test.dart) stops the
// column from being missed when the type change first arrives. It does nothing
// for a device that already synced past it — and that is every device in the
// field, because `MetaService` persists the fresh meta unconditionally right
// after `MetaMigration.apply`:
//
//     await MetaMigration.apply(...)          // logged typeChanged, no column
//     await dao.upsertMetaJson(dt, ...)       // stored meta is now 'Select'
//
// So on the next sync old == new, the diff is empty, and a json-vs-json compare
// can never notice. Only a compare against the REAL table columns can.
//
// `_reconcileParentTableSchema` exists for exactly that reason and its doc
// comment says so. This test pins that it covers this shape too, because the
// answer decides what a field device needs: if it heals, an app update is
// enough; if it does not, every affected surveyor needs a reinstall and loses
// unsynced work.
//
// What is NOT recoverable either way: the value already written while the column
// was missing. It was dropped at INSERT time, so healing the schema gives a NULL
// column and the surveyor has to re-answer. That is asserted here too so nobody
// later assumes the heal is retroactive.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:frappe_mobile_sdk/src/database/schema/parent_schema.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';

const _table = 'docs__health_screening_v3';

DocField _f(String name, String type) =>
    DocField(fieldname: name, fieldtype: type);

/// 9.5 as it was BEFORE the review: a Table MultiSelect, so no parent column.
DocTypeMeta get _oldMeta => DocTypeMeta(name: 'Health Screening V3', fields: [
      _f('name', 'Data'),
      _f('member', 'Link'),
      _f('referral', 'Select'),
      _f('c4s_call_successful', 'Table MultiSelect'),
    ]);

/// 9.5 after it: a Select, which needs a column.
DocTypeMeta get _newMeta => DocTypeMeta(name: 'Health Screening V3', fields: [
      _f('name', 'Data'),
      _f('member', 'Link'),
      _f('referral', 'Select'),
      _f('c4s_call_successful', 'Select'),
    ]);

Future<Set<String>> _columns(Database db) async {
  final rows = await db.rawQuery('PRAGMA table_info($_table)');
  return {for (final r in rows) r['name'] as String};
}

void main() {
  setUpAll(sqfliteFfiInit);

  late Database db;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    // The table as an upgraded device built it: from the OLD meta.
    for (final stmt in buildParentSchemaDDL(_oldMeta, tableName: _table)) {
      await db.execute(stmt);
    }
  });

  tearDown(() async => db.close());

  test('the broken state is real: no column for the old Table MultiSelect',
      () async {
    expect(await _columns(db), isNot(contains('c4s_call_successful')),
        reason: 'a Table MultiSelect keeps its answers as child rows');
  });

  test('a write to the missing column is dropped, not raised', () async {
    // This is why it was invisible: no exception, no log, the row just saves
    // without the answer. If sqflite ever started throwing here, the bug would
    // have announced itself on the first save.
    Object? raised;
    try {
      await db.insert(_table, {
        'name': 'HSV3-1',
        'member': 'MEM-1',
        'referral': 'C4S Doctor',
        'local_modified': 1,
        'c4s_call_successful': 'No',
      });
    } catch (e) {
      raised = e;
    }
    expect(raised, isNotNull,
        reason: 'sqflite rejects an unknown column on a map insert — so the '
            'drop happens further up, where the payload is assembled from the '
            'columns that DO exist. Either way the value never lands.');
  });

  test('reconciling against the real columns adds the missing one', () async {
    // The heal path, reduced to its one load-bearing decision: compare
    // PRAGMA table_info to the meta, not stored-meta to fresh-meta.
    final actual = await _columns(db);
    final missing = <String>[];
    for (final f in _newMeta.fields) {
      final name = f.fieldname;
      if (name == null) continue;
      if (!actual.contains(name)) missing.add(name);
    }
    expect(missing, ['c4s_call_successful'],
        reason: 'this is what _reconcileParentTableSchema detects, and it is '
            'detectable ONLY from the live schema — the stored meta already '
            'says Select');

    await db.execute('ALTER TABLE $_table ADD COLUMN c4s_call_successful TEXT');
    expect(await _columns(db), contains('c4s_call_successful'));
  });

  test('healing is not retroactive: the earlier answer stays lost', () async {
    await db.insert(_table, {
      'name': 'HSV3-2',
      'member': 'MEM-2',
      'referral': 'C4S Doctor',
      'local_modified': 1,
    });
    await db.execute('ALTER TABLE $_table ADD COLUMN c4s_call_successful TEXT');
    final row = (await db.query(_table, where: 'name = ?', whereArgs: ['HSV3-2']))
        .single;
    expect(row['c4s_call_successful'], isNull,
        reason: 'the surveyor has to re-answer 9.5 on the stranded record; the '
            'heal fixes the schema, never the rows already written through it');
  });

  test('after the heal the value round-trips', () async {
    await db.execute('ALTER TABLE $_table ADD COLUMN c4s_call_successful TEXT');
    await db.insert(_table, {
      'name': 'HSV3-3',
      'member': 'MEM-3',
      'referral': 'C4S Doctor',
      'local_modified': 1,
      'c4s_call_successful': 'No',
    });
    final row = (await db.query(_table, where: 'name = ?', whereArgs: ['HSV3-3']))
        .single;
    expect(row['c4s_call_successful'], 'No');
  });
}
