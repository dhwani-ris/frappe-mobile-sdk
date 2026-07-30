// A child doctype named `autoincrement` has an INTEGER primary key, so its
// `name` arrives from Frappe as a JSON number. `pull_apply` used to read it
// with `cr['name'] as String?`, which throws:
//
//   type 'int' is not a subtype of type 'String?' in type cast
//
// The throw escapes the per-doctype pull, so the WHOLE doctype fails — not one
// row — and the first-sync screen reports it as a required item that did not
// finish.
//
// Found on staging 2026-07-30: the PM could not sync Livelihood Application or
// Livelihood Goat Purchase Followup at all. Their Table MultiSelect children
// (Goat Training Item / Goat Sex Item / Market Channel Item) are all declared
// `autoname: "autoincrement"`. It was dormant for three months because those
// tables were empty; the first Livelihood test data created the first rows and
// broke that surveyor's sync from then on.
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/sync/pull_apply.dart';
import 'package:frappe_mobile_sdk/src/database/schema/parent_schema.dart';
import 'package:frappe_mobile_sdk/src/database/schema/child_schema.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DocField f(String n, String t, {String? options}) =>
    DocField(fieldname: n, fieldtype: t, label: n, options: options);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late DocTypeMeta parentMeta;
  late DocTypeMeta childMeta;

  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    parentMeta = DocTypeMeta(
      name: 'Livelihood Application',
      fields: [
        f('member', 'Link', options: 'Member'),
        f('goat_training_completed', 'Table MultiSelect',
            options: 'Livelihood Goat Training Item'),
      ],
    );
    childMeta = DocTypeMeta(
      name: 'Livelihood Goat Training Item',
      isTable: true,
      fields: [f('training_item', 'Link', options: 'Goat Training Type')],
    );
    for (final s in buildParentSchemaDDL(parentMeta,
        tableName: 'docs__livelihood_application')) {
      await db.execute(s);
    }
    for (final s in buildChildSchemaDDL(childMeta,
        tableName: 'docs__livelihood_goat_training_item')) {
      await db.execute(s);
    }
  });

  tearDown(() async => db.close());

  Future<void> pull(Object childName) => PullApply.applyPage(
        db: db,
        parentMeta: parentMeta,
        parentTable: 'docs__livelihood_application',
        childMetasByFieldname: {
          'goat_training_completed': PullApplyChildInfo(
              'Livelihood Goat Training Item', childMeta),
        },
        rows: [
          {
            'name': 'LA-2026-0001',
            'modified': '2026-07-30 00:03:41',
            'member': 'MEM-1',
            'goat_training_completed': [
              // exactly what Frappe sends for an autoincrement child
              {'name': childName, 'training_item': 'Basic Goat Care'},
            ],
          },
        ],
      );

  test('an INTEGER child name does not abort the pull', () async {
    await pull(94); // the real value observed on staging

    final parent = await db.query('docs__livelihood_application');
    expect(parent.length, 1, reason: 'the parent must still land');

    final child = await db.query('docs__livelihood_goat_training_item');
    expect(child.length, 1, reason: 'the child row must still land');
    expect(child.first['server_name'], '94',
        reason: 'stored as its string form — server_name is a TEXT column');
    expect(child.first['training_item'], 'Basic Goat Care');
  });

  test('a STRING child name still behaves exactly as before', () async {
    await pull('abc123def');
    final child = await db.query('docs__livelihood_goat_training_item');
    expect(child.length, 1);
    expect(child.first['server_name'], 'abc123def');
  });

  test('re-pulling an integer-named child preserves its mobile_uuid', () async {
    await pull(94);
    final first = (await db.query('docs__livelihood_goat_training_item')).first;
    final uuid = first['mobile_uuid'];
    expect(uuid, isNotNull);

    await pull(94); // same row arrives again on the next sync
    final rows = await db.query('docs__livelihood_goat_training_item');
    expect(rows.length, 1, reason: 'must not duplicate the child');
    expect(rows.first['mobile_uuid'], uuid,
        reason: 'server_name matching must still work with an int name');
  });
}
