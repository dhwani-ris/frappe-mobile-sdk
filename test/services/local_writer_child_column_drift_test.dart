import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/schema/child_schema.dart';
import 'package:frappe_mobile_sdk/src/database/schema/parent_schema.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/services/local_writer.dart';
import 'package:frappe_mobile_sdk/src/utils/mobile_creation_stamp.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DocField _f(String n, String t, {String? options}) =>
    DocField(fieldname: n, fieldtype: t, label: n, options: options);

final _parentMeta = DocTypeMeta(
  name: 'Order',
  fields: [
    _f('title', 'Data'),
    _f('items', 'Table', options: 'Order Item'),
  ],
);

/// The child doctype AS THE TABLE WAS BUILT — before mobile_control added its
/// Custom Fields.
final _childMetaOld = DocTypeMeta(
  name: 'Order Item',
  isTable: true,
  fields: [_f('item_name', 'Data')],
);

/// The same child doctype as the CURRENT meta describes it, after
/// mobile_control provisioned the two capture fields.
final _childMetaNew = DocTypeMeta(
  name: 'Order Item',
  isTable: true,
  fields: [
    _f('item_name', 'Data'),
    _f(mobileCreatedAtField, 'Datetime'),
    _f(mobileLatitudeLongitudeField, 'Geolocation'),
  ],
);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;

  Future<LocalWriter> writerFor(DocTypeMeta childMeta) async {
    return LocalWriter(db, (dt) async {
      if (dt == 'Order') return _parentMeta;
      if (dt == 'Order Item') return childMeta;
      throw StateError('unexpected meta lookup: $dt');
    });
  }

  /// Builds the parent table plus a child table from [childTableMeta], which is
  /// how an install that predates a child field ends up with a narrow table.
  Future<void> openWith(DocTypeMeta childTableMeta) async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    for (final s in buildParentSchemaDDL(
      _parentMeta,
      tableName: 'docs__order',
    )) {
      await db.execute(s);
    }
    for (final s in buildChildSchemaDDL(
      childTableMeta,
      tableName: 'docs__order_item',
    )) {
      await db.execute(s);
    }
  }

  tearDown(() async => db.close());

  test('child stamps land when the table has the columns', () async {
    await openWith(_childMetaNew);
    final writer = await writerFor(_childMetaNew);

    await writer.writeParent(
      parentDoctype: 'Order',
      data: {
        'mobile_uuid': 'p1',
        'title': 'order',
        'items': [
          {
            'item_name': 'item 1',
            mobileCreatedAtField: '2026-08-18 09:05:03',
            mobileLatitudeLongitudeField: 'GEO',
          },
        ],
      },
    );

    final rows = await db.query('docs__order_item');
    expect(rows, hasLength(1));
    expect(rows.first[mobileCreatedAtField], '2026-08-18 09:05:03');
    expect(rows.first[mobileLatitudeLongitudeField], 'GEO');
  });

  test(
    'a child column the table lacks is skipped, not allowed to fail the save',
    () async {
      // The drift an existing install has: table built from the OLD child meta,
      // writer driven by the NEW one. `saveDocument` reconciles only the PARENT
      // table, so nothing ever adds these columns here.
      await openWith(_childMetaOld);
      final writer = await writerFor(_childMetaNew);

      await writer.writeParent(
        parentDoctype: 'Order',
        data: {
          'mobile_uuid': 'p1',
          'title': 'order',
          'items': [
            {
              'item_name': 'item 1',
              mobileCreatedAtField: '2026-08-18 09:05:03',
              mobileLatitudeLongitudeField: 'GEO',
            },
          ],
        },
      );

      // The whole point: the record survives. Before the guard this threw
      // "no such column: mobile_created_at" from inside the transaction and
      // took the parent row down with it.
      final parents = await db.query('docs__order');
      expect(parents, hasLength(1));
      expect(parents.first['title'], 'order');

      final rows = await db.query('docs__order_item');
      expect(rows, hasLength(1));
      expect(rows.first['item_name'], 'item 1');
      expect(
        rows.first.containsKey(mobileCreatedAtField),
        isFalse,
        reason: 'the column genuinely is not there',
      );
    },
  );
}
