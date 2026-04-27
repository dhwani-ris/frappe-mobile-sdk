import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/schema/child_schema.dart';
import 'package:frappe_mobile_sdk/src/database/schema/parent_schema.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/services/local_writer.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DocField f(String n, String t, {String? options}) =>
    DocField(fieldname: n, fieldtype: t, label: n, options: options);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late LocalWriter writer;

  // Generic parent + child shape: parent has a Table field whose `options`
  // points to a child doctype (istable=1).
  final parentMeta = DocTypeMeta(
    name: 'Order',
    titleField: 'title',
    fields: [
      f('title', 'Data'),
      f('customer', 'Link', options: 'Customer'),
      f('items', 'Table', options: 'Order Item'),
    ],
  );
  final childMeta = DocTypeMeta(
    name: 'Order Item',
    isTable: true,
    fields: [
      f('item_name', 'Data'),
      f('size', 'Data'),
      f('color', 'Select'),
    ],
  );

  Future<DocTypeMeta> metaFn(String dt) async {
    if (dt == 'Order') return parentMeta;
    if (dt == 'Order Item') return childMeta;
    throw StateError('unexpected meta lookup: $dt');
  }

  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    for (final s
        in buildParentSchemaDDL(parentMeta, tableName: 'docs__order')) {
      await db.execute(s);
    }
    for (final s
        in buildChildSchemaDDL(childMeta, tableName: 'docs__order_item')) {
      await db.execute(s);
    }
    writer = LocalWriter(db, metaFn);
  });

  tearDown(() async => db.close());

  test('writes parent + splits Table children into per-doctype tables',
      () async {
    final mobileUuid = await writer.writeParent(
      parentDoctype: 'Order',
      data: {
        'mobile_uuid': 'p-uuid-1',
        'title': 'offline order 1',
        'customer': 'CUST-001',
        'items': [
          {'item_name': 'item 1', 'size': 'L', 'color': 'Red'},
          {'item_name': 'item 2', 'size': 'M', 'color': 'Blue'},
        ],
      },
    );

    expect(mobileUuid, 'p-uuid-1');

    final parentRows = await db.query('docs__order');
    expect(parentRows, hasLength(1));
    expect(parentRows.first['mobile_uuid'], 'p-uuid-1');
    expect(parentRows.first['server_name'], isNull);
    expect(parentRows.first['sync_status'], 'dirty');
    expect(parentRows.first['title'], 'offline order 1');
    expect(parentRows.first['customer'], 'CUST-001');
    expect(parentRows.first['customer__is_local'], 0,
        reason: 'customer value "CUST-001" is a server name from initial pull');

    final childRows = await db.query('docs__order_item', orderBy: 'idx ASC');
    expect(childRows, hasLength(2));
    expect(childRows[0]['parent_uuid'], 'p-uuid-1');
    expect(childRows[0]['parent_doctype'], 'Order');
    expect(childRows[0]['parentfield'], 'items');
    expect(childRows[0]['idx'], 0);
    expect(childRows[0]['item_name'], 'item 1');
    expect(childRows[1]['item_name'], 'item 2');
    expect(childRows[1]['idx'], 1);
  });

  test('re-saving the same parent replaces children atomically', () async {
    await writer.writeParent(
      parentDoctype: 'Order',
      data: {
        'mobile_uuid': 'p-uuid-2',
        'title': 'first save',
        'items': [
          {'item_name': 'A'},
          {'item_name': 'B'},
          {'item_name': 'C'},
        ],
      },
    );

    await writer.writeParent(
      parentDoctype: 'Order',
      data: {
        'mobile_uuid': 'p-uuid-2',
        'title': 'second save',
        'items': [
          {'item_name': 'X'},
        ],
      },
    );

    final parentRows = await db.query('docs__order');
    expect(parentRows, hasLength(1));
    expect(parentRows.first['title'], 'second save');

    final childRows = await db.query('docs__order_item');
    expect(childRows, hasLength(1));
    expect(childRows.first['item_name'], 'X');
    expect(childRows.first['parent_uuid'], 'p-uuid-2');
  });

  test('markSynced sets server_name + sync_status=synced', () async {
    await writer.writeParent(
      parentDoctype: 'Order',
      data: {
        'mobile_uuid': 'p-uuid-3',
        'title': 'pending push',
      },
    );

    await writer.markSynced(
      parentDoctype: 'Order',
      mobileUuid: 'p-uuid-3',
      serverName: 'ORD-00042',
    );

    final rows = await db.query('docs__order',
        where: 'mobile_uuid = ?', whereArgs: ['p-uuid-3']);
    expect(rows.first['server_name'], 'ORD-00042');
    expect(rows.first['sync_status'], 'synced');
  });

  test('writeParent with serverName marks row synced + is_local=0', () async {
    await writer.writeParent(
      parentDoctype: 'Order',
      data: {
        'mobile_uuid': 'p-uuid-4',
        'title': 'server returned',
        'customer': 'CUST-001',
      },
      serverName: 'ORD-00099',
    );

    final rows = await db.query('docs__order',
        where: 'mobile_uuid = ?', whereArgs: ['p-uuid-4']);
    expect(rows.first['server_name'], 'ORD-00099');
    expect(rows.first['sync_status'], 'synced');
    expect(rows.first['customer__is_local'], 0);
  });

  test('no-op when parent table not yet created (initial sync pending)',
      () async {
    await db.execute('DROP TABLE docs__order');

    final uuid = await writer.writeParent(
      parentDoctype: 'Order',
      data: {
        'mobile_uuid': 'p-uuid-5',
        'title': 'no parent table',
        'items': [
          {'item_name': 'X'},
        ],
      },
    );

    expect(uuid, 'p-uuid-5');
    final childRows = await db.query('docs__order_item');
    expect(childRows, isEmpty,
        reason: 'when parent table missing, the whole transaction is a no-op');
  });
}
