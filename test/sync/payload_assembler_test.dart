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
    for (final s in buildParentSchemaDDL(
      parentMeta,
      tableName: 'docs__sales_order',
    )) {
      await db.execute(s);
    }
    for (final s in buildChildSchemaDDL(
      childMeta,
      tableName: 'docs__so_item',
    )) {
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
        resolveServerName: (_, _) async => null,
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
      resolveServerName: (_, _) async => null,
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
      resolveServerName: (_, _) async => null,
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
        resolveServerName: (_, _) async => null,
      ),
      throwsA(isA<BlockedByUpstream>()),
    );
  });

  test(
    'throws ServerRejection (not StateError) when parent row missing',
    () async {
      // Outbox row points to a mobile_uuid that doesn't exist in the
      // per-doctype mirror — happens when the row is deleted between
      // outbox-insert and push-run. Previously crashed with `StateError:
      // No element` from `.first`; must now surface a structured error
      // so the outbox row is marked failed cleanly.
      final row = OutboxRow(
        id: 1,
        doctype: 'Sales Order',
        mobileUuid: 'ghost-uuid',
        operation: OutboxOperation.update,
        state: OutboxState.pending,
        retryCount: 0,
        createdAt: DateTime.utc(2026, 1, 1),
        serverName: 'SO-DELETED',
      );
      expect(
        () => PayloadAssembler.assemble(
          db: db,
          row: row,
          parentMeta: parentMeta,
          parentTable: 'docs__sales_order',
          childMetasByFieldname: const {},
          resolveServerName: (_, _) async => null,
        ),
        throwsA(isA<ServerRejection>()),
      );
    },
  );

  group('child rows carry their mobile_uuid', () {
    // The parent's uuid was re-added explicitly after the system-column strip;
    // children were stripped and never re-added, so the server stored child
    // `mobile_uuid` as NULL and the pull path's child adopt branch could only
    // ever fire for a value someone set in Desk. `mobile_control` already
    // provisions the field on child doctypes (unique, read_only), so the wire
    // was the only missing half.
    OutboxRow rowFor(OutboxOperation op) => OutboxRow(
      id: 1,
      doctype: 'Sales Order',
      mobileUuid: 'u-so-1',
      operation: op,
      state: OutboxState.pending,
      retryCount: 0,
      createdAt: DateTime.utc(2026, 1, 1),
    );

    Future<List<dynamic>> itemsFor(OutboxOperation op) async {
      final payload = await PayloadAssembler.assemble(
        db: db,
        row: rowFor(op),
        parentMeta: parentMeta,
        parentTable: 'docs__sales_order',
        childMetasByFieldname: {
          'items': _ChildInfo('SO Item', childMeta, 'docs__so_item'),
        },
        resolveServerName: (_, _) async => null,
      );
      return payload['items'] as List;
    }

    test('on INSERT, each child sends its own uuid', () async {
      final items = await itemsFor(OutboxOperation.insert);
      expect(items.length, 2);
      expect(items[0]['mobile_uuid'], 'c-1');
      expect(items[1]['mobile_uuid'], 'c-2');
    });

    test('on UPDATE too — the uuid is not insert-only', () async {
      final items = await itemsFor(OutboxOperation.update);
      expect(items[0]['mobile_uuid'], 'c-1');
      expect(items[1]['mobile_uuid'], 'c-2');
    });

    test('each child keeps its OWN uuid, never the parent\'s', () async {
      // The bug this guards is a copy-paste of `row.mobileUuid` into the child
      // seed, which would give every child the parent's uuid and collide on the
      // server's UNIQUE index the moment a second child was sent.
      final items = await itemsFor(OutboxOperation.insert);
      final uuids = items.map((i) => i['mobile_uuid']).toList();
      expect(uuids, ['c-1', 'c-2']);
      expect(uuids.toSet().length, 2, reason: 'uuids must be distinct');
      expect(uuids, isNot(contains('u-so-1')));
    });

    test('an empty child uuid is omitted rather than sent blank', () async {
      // `mobile_uuid` is UNIQUE server-side, and MariaDB permits many NULLs but
      // not many ''. Sending a blank would fail the second such row's insert,
      // so omit the key entirely and let the server keep NULL.
      await db.insert('docs__so_item', {
        'mobile_uuid': 'c-3',
        'parent_uuid': 'u-so-1',
        'parent_doctype': 'Sales Order',
        'parentfield': 'items',
        'idx': 2,
        'item_code': 'C',
        'qty': 1,
      });
      await db.update(
        'docs__so_item',
        {'mobile_uuid': ''},
        where: 'mobile_uuid = ?',
        whereArgs: ['c-3'],
      );

      final items = await itemsFor(OutboxOperation.insert);
      final blank = items.firstWhere((i) => i['item_code'] == 'C');
      expect(
        (blank as Map).containsKey('mobile_uuid'),
        isFalse,
        reason: 'a blank uuid must not reach a UNIQUE column',
      );
    });
  });
}
