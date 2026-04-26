import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/sync/payload_assembler.dart';
import 'package:frappe_mobile_sdk/src/sync/push_error.dart';
import 'package:frappe_mobile_sdk/src/database/schema/parent_schema.dart';
import 'package:frappe_mobile_sdk/src/database/schema/child_schema.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/outbox_row.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DocField f(String n, String t, {String? options}) =>
    DocField(fieldname: n, fieldtype: t, label: n, options: options);

class _ChildInfo implements ChildInfo {
  @override
  final String doctype;
  @override
  final DocTypeMeta meta;
  @override
  final String tableName;
  _ChildInfo(this.doctype, this.meta, this.tableName);
}

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
      name: 'Sales Order',
      fields: [
        f('customer', 'Link', options: 'Customer'),
        f('grand_total', 'Currency'),
        f('items', 'Table', options: 'SO Item'),
      ],
    );
    childMeta = DocTypeMeta(
      name: 'SO Item',
      isTable: true,
      fields: [f('item_code', 'Data'), f('qty', 'Int')],
    );
    for (final s in buildParentSchemaDDL(parentMeta, tableName: 'docs__sales_order')) {
      await db.execute(s);
    }
    for (final s in buildChildSchemaDDL(childMeta, tableName: 'docs__so_item')) {
      await db.execute(s);
    }
    await db.insert('docs__sales_order', {
      'mobile_uuid': 'u-so-1',
      'server_name': null,
      'sync_status': 'dirty',
      'local_modified': 1,
      'customer': 'CUST-1',
      'grand_total': 100.0,
    });
    await db.insert('docs__so_item', {
      'mobile_uuid': 'c-1',
      'parent_uuid': 'u-so-1',
      'parent_doctype': 'Sales Order',
      'parentfield': 'items',
      'idx': 0,
      'item_code': 'A',
      'qty': 2,
    });
    await db.insert('docs__so_item', {
      'mobile_uuid': 'c-2',
      'parent_uuid': 'u-so-1',
      'parent_doctype': 'Sales Order',
      'parentfield': 'items',
      'idx': 1,
      'item_code': 'B',
      'qty': 3,
    });
  });

  tearDown(() async => db.close());

  test(
    'INSERT payload includes parent fields + nested children + mobile_uuid',
    () async {
      final row = OutboxRow(
        id: 1,
        doctype: 'Sales Order',
        mobileUuid: 'u-so-1',
        operation: OutboxOperation.insert,
        state: OutboxState.pending,
        retryCount: 0,
        createdAt: DateTime.utc(2026, 1, 1),
      );
      final payload = await PayloadAssembler.assemble(
        db: db,
        row: row,
        parentMeta: parentMeta,
        parentTable: 'docs__sales_order',
        childMetasByFieldname: {
          'items': _ChildInfo('SO Item', childMeta, 'docs__so_item'),
        },
        resolveServerName: (_, __) async => null,
      );
      expect(payload['doctype'], 'Sales Order');
      expect(payload['mobile_uuid'], 'u-so-1');
      expect(payload['customer'], 'CUST-1');
      expect(payload['grand_total'], 100.0);
      final items = payload['items'] as List;
      expect(items.length, 2);
      expect(items[0]['item_code'], 'A');
      expect(items[0]['idx'], 0);
      expect(items[1]['idx'], 1);
    },
  );

  test('UPDATE payload includes modified from snapshot', () async {
    await db.update(
      'docs__sales_order',
      {'modified': '2026-01-15 10:00:00'},
      where: 'mobile_uuid=?',
      whereArgs: ['u-so-1'],
    );
    final row = OutboxRow(
      id: 1,
      doctype: 'Sales Order',
      mobileUuid: 'u-so-1',
      operation: OutboxOperation.update,
      state: OutboxState.pending,
      retryCount: 0,
      createdAt: DateTime.utc(2026, 1, 1),
    );
    final payload = await PayloadAssembler.assemble(
      db: db,
      row: row,
      parentMeta: parentMeta,
      parentTable: 'docs__sales_order',
      childMetasByFieldname: {
        'items': _ChildInfo('SO Item', childMeta, 'docs__so_item'),
      },
      resolveServerName: (_, __) async => null,
    );
    expect(payload['modified'], '2026-01-15 10:00:00');
  });

  test('system columns excluded from payload', () async {
    final row = OutboxRow(
      id: 1,
      doctype: 'Sales Order',
      mobileUuid: 'u-so-1',
      operation: OutboxOperation.insert,
      state: OutboxState.pending,
      retryCount: 0,
      createdAt: DateTime.utc(2026, 1, 1),
    );
    final payload = await PayloadAssembler.assemble(
      db: db,
      row: row,
      parentMeta: parentMeta,
      parentTable: 'docs__sales_order',
      childMetasByFieldname: {
        'items': _ChildInfo('SO Item', childMeta, 'docs__so_item'),
      },
      resolveServerName: (_, __) async => null,
    );
    for (final sys in [
      'sync_status',
      'sync_error',
      'sync_attempts',
      'sync_op',
      'local_modified',
      'pulled_at',
    ]) {
      expect(payload.containsKey(sys), isFalse, reason: 'should drop $sys');
    }
  });

  test('throws BlockedByUpstream when a Link target UUID unresolved', () async {
    await db.update(
      'docs__sales_order',
      {'customer': 'u-newcust', 'customer__is_local': 1},
      where: 'mobile_uuid=?',
      whereArgs: ['u-so-1'],
    );
    final row = OutboxRow(
      id: 1,
      doctype: 'Sales Order',
      mobileUuid: 'u-so-1',
      operation: OutboxOperation.insert,
      state: OutboxState.pending,
      retryCount: 0,
      createdAt: DateTime.utc(2026, 1, 1),
    );
    await expectLater(
      PayloadAssembler.assemble(
        db: db,
        row: row,
        parentMeta: parentMeta,
        parentTable: 'docs__sales_order',
        childMetasByFieldname: {
          'items': _ChildInfo('SO Item', childMeta, 'docs__so_item'),
        },
        resolveServerName: (_, __) async => null,
      ),
      throwsA(isA<BlockedByUpstream>()),
    );
  });
}
