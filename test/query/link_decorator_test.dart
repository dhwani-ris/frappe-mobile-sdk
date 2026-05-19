import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/schema/parent_schema.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/query/link_decorator.dart';
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
    final custMeta = DocTypeMeta(
      name: 'Customer',
      titleField: 'customer_name',
      fields: [f('customer_name', 'Data')],
    );
    for (final s
        in buildParentSchemaDDL(custMeta, tableName: 'docs__customer')) {
      await db.execute(s);
    }
    await db.insert('docs__customer', {
      'mobile_uuid': 'u-new',
      'sync_status': 'dirty',
      'local_modified': 1,
      'customer_name': 'Pending Customer',
    });
    await db.insert('docs__customer', {
      'mobile_uuid': 'u-existing',
      'server_name': 'CUST-1',
      'sync_status': 'synced',
      'local_modified': 1,
      'customer_name': 'ACME',
    });
  });
  tearDown(() async => db.close());

  test('decorates local Link with target title', () async {
    final soMeta = DocTypeMeta(
      name: 'SO',
      fields: [f('customer', 'Link', options: 'Customer')],
    );
    final row = <String, Object?>{
      'customer': 'u-new',
      'customer__is_local': 1,
    };
    final out = await LinkDecorator.decorate(
      db: db,
      parentMeta: soMeta,
      row: row,
      targetMetaResolver: (dt) async => DocTypeMeta(
        name: dt,
        titleField: 'customer_name',
        fields: [f('customer_name', 'Data')],
      ),
    );
    expect(out['customer__display'], 'Pending Customer');
  });

  test('server-known Link uses titleField from server row', () async {
    final soMeta = DocTypeMeta(
      name: 'SO',
      fields: [f('customer', 'Link', options: 'Customer')],
    );
    final row = <String, Object?>{
      'customer': 'CUST-1',
      'customer__is_local': 0,
    };
    final out = await LinkDecorator.decorate(
      db: db,
      parentMeta: soMeta,
      row: row,
      targetMetaResolver: (dt) async => DocTypeMeta(
        name: dt,
        titleField: 'customer_name',
        fields: [f('customer_name', 'Data')],
      ),
    );
    expect(out['customer__display'], 'ACME');
  });

  test('missing target row → __display falls back to raw value', () async {
    final soMeta = DocTypeMeta(
      name: 'SO',
      fields: [f('customer', 'Link', options: 'Customer')],
    );
    final row = <String, Object?>{
      'customer': 'u-missing',
      'customer__is_local': 1,
    };
    final out = await LinkDecorator.decorate(
      db: db,
      parentMeta: soMeta,
      row: row,
      targetMetaResolver: (dt) async => DocTypeMeta(
        name: dt,
        titleField: 'customer_name',
        fields: [f('customer_name', 'Data')],
      ),
    );
    expect(out['customer__display'], 'u-missing');
  });

  test('null link value passes through without lookup', () async {
    final soMeta = DocTypeMeta(
      name: 'SO',
      fields: [f('customer', 'Link', options: 'Customer')],
    );
    final row = <String, Object?>{'customer': null};
    final out = await LinkDecorator.decorate(
      db: db,
      parentMeta: soMeta,
      row: row,
      targetMetaResolver: (dt) async =>
          throw StateError('should not be called for null'),
    );
    expect(out.containsKey('customer__display'), isFalse);
  });

  test('missing target table → __display falls back to raw value', () async {
    final soMeta = DocTypeMeta(
      name: 'SO',
      fields: [f('item', 'Link', options: 'Item')], // no docs__item created
    );
    final row = <String, Object?>{
      'item': 'ITEM-1',
      'item__is_local': 0,
    };
    final out = await LinkDecorator.decorate(
      db: db,
      parentMeta: soMeta,
      row: row,
      targetMetaResolver: (dt) async => DocTypeMeta(
        name: dt,
        titleField: 'item_name',
        fields: [f('item_name', 'Data')],
      ),
    );
    expect(out['item__display'], 'ITEM-1');
  });

  test('Dynamic Link: target doctype read from sibling field', () async {
    final commentMeta = DocTypeMeta(
      name: 'Comment',
      fields: [
        f('reference_doctype', 'Data'),
        f('reference_name', 'Dynamic Link', options: 'reference_doctype'),
      ],
    );
    final row = <String, Object?>{
      'reference_doctype': 'Customer',
      'reference_name': 'CUST-1',
      'reference_name__is_local': 0,
    };
    final out = await LinkDecorator.decorate(
      db: db,
      parentMeta: commentMeta,
      row: row,
      targetMetaResolver: (dt) async => DocTypeMeta(
        name: dt,
        titleField: 'customer_name',
        fields: [f('customer_name', 'Data')],
      ),
    );
    expect(out['reference_name__display'], 'ACME');
  });
}
