import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/concurrency/concurrency_pool.dart';
import 'package:frappe_mobile_sdk/src/database/daos/doctype_meta_dao.dart';
import 'package:frappe_mobile_sdk/src/database/daos/outbox_dao.dart';
import 'package:frappe_mobile_sdk/src/database/daos/pending_attachment_dao.dart';
import 'package:frappe_mobile_sdk/src/database/schema/child_schema.dart';
import 'package:frappe_mobile_sdk/src/database/schema/parent_schema.dart';
import 'package:frappe_mobile_sdk/src/database/schema/system_tables.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/outbox_row.dart';
import 'package:frappe_mobile_sdk/src/sync/idempotency_strategy.dart';
import 'package:frappe_mobile_sdk/src/sync/push_engine.dart';
import 'package:frappe_mobile_sdk/src/sync/response_writeback.dart';
import 'package:frappe_mobile_sdk/src/sync/sync_state_notifier.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DocField f(String n, String t, {String? options}) =>
    DocField(fieldname: n, fieldtype: t, label: n, options: options);

/// Opt-in server-field writeback (`FrappeSDK.writeBackDoctypes`): fields the
/// server sets on save land in the local row straight from the push response.
/// All data here is fictional.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  // The meta the device has. `remarks` is declared in meta but deliberately
  // left out of the table DDL below (meta newer than the schema).
  final parentMeta = DocTypeMeta(
    name: 'Sales Invoice',
    titleField: 'customer_name',
    fields: [
      f('customer_name', 'Data'),
      f('invoice_no', 'Data'),
      f('grand_total', 'Currency'),
      f('status', 'Select'),
      f('customer', 'Link', options: 'Customer'),
      f('payload_json', 'JSON'),
      f('remarks', 'Small Text'),
      f('items', 'Table', options: 'SI Item'),
    ],
  );
  final schemaMeta = DocTypeMeta(
    name: 'Sales Invoice',
    titleField: 'customer_name',
    fields: parentMeta.fields.where((x) => x.fieldname != 'remarks').toList(),
  );
  final childMeta = DocTypeMeta(
    name: 'SI Item',
    isTable: true,
    fields: [f('qty', 'Int'), f('amount', 'Currency')],
  );

  late Database db;
  late OutboxDao outbox;

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
    for (final s in doctypeMetaExtensionsDDL()) {
      await db.execute(s);
    }
    for (final s in systemTablesDDL()) {
      await db.execute(s);
    }
    for (final s in buildParentSchemaDDL(
      schemaMeta,
      tableName: 'docs__sales_invoice',
    )) {
      await db.execute(s);
    }
    for (final s in buildChildSchemaDDL(
      childMeta,
      tableName: 'docs__si_item',
    )) {
      await db.execute(s);
    }
    await db.insert('doctype_meta', {
      'doctype': 'Sales Invoice',
      'metaJson': '{}',
      'isMobileForm': 0,
      'table_name': 'docs__sales_invoice',
    });

    outbox = OutboxDao(db);
    await db.insert('docs__sales_invoice', {
      'mobile_uuid': 'u-si',
      'sync_status': 'dirty',
      'local_modified': 1,
      'customer_name': 'Asha Devi',
      'status': 'Draft',
      'customer': 'b3f1c2d4-0000-4000-8000-000000000001',
      'customer__is_local': 1,
    });
    await db.insert('docs__si_item', {
      'mobile_uuid': 'c-1',
      'parent_uuid': 'u-si',
      'parent_doctype': 'Sales Invoice',
      'parentfield': 'items',
      'idx': 0,
      'qty': 2,
    });
    await db.insert('docs__si_item', {
      'mobile_uuid': 'c-2',
      'parent_uuid': 'u-si',
      'parent_doctype': 'Sales Invoice',
      'parentfield': 'items',
      'idx': 1,
      'qty': 3,
    });
    await outbox.insertPending(
      doctype: 'Sales Invoice',
      mobileUuid: 'u-si',
      operation: OutboxOperation.insert,
    );
  });

  tearDown(() async => db.close());

  Map<String, dynamic> serverResponse() => {
    'name': 'SINV-0001',
    'modified': '2026-02-01 10:00:00',
    'docstatus': 0,
    'customer_name': 'Asha Devi',
    'invoice_no': 'INV-2026-0001',
    'grand_total': 450.5,
    'status': 'Unpaid',
    'customer': 'CUST-0007',
    'items': [
      // First child echoes its mobile_uuid; second is matched by position.
      {
        'name': 'SII-1',
        'idx': 1,
        'modified': '2026-02-01 10:00:00',
        'mobile_uuid': 'c-1',
        'qty': 2,
        'amount': 200.0,
      },
      {
        'name': 'SII-2',
        'idx': 2,
        'modified': '2026-02-01 10:00:00',
        'qty': 3,
        'amount': 250.5,
      },
    ],
  };

  Future<void> apply(Map<String, dynamic> response, {bool optIn = true}) async {
    final outboxRow = (await outbox.findByState(OutboxState.pending)).first;
    await ResponseWriteback.apply(
      db: db,
      row: outboxRow,
      parentTable: 'docs__sales_invoice',
      childTablesByFieldname: const {'items': 'docs__si_item'},
      response: response,
      writeBackMeta: optIn ? parentMeta : null,
      writeBackChildMetas: optIn ? {'items': childMeta} : const {},
    );
  }

  Future<Map<String, Object?>> parent() async =>
      (await db.query('docs__sales_invoice')).first;

  Future<Map<String, Object?>> child(String uuid) async => (await db.query(
    'docs__si_item',
    where: 'mobile_uuid = ?',
    whereArgs: [uuid],
  )).first;

  test('opted in: server-computed parent fields land locally', () async {
    await apply(serverResponse());
    final p = await parent();
    expect(p['server_name'], 'SINV-0001');
    expect(p['sync_status'], 'synced');
    expect(p['invoice_no'], 'INV-2026-0001');
    expect(p['grand_total'], 450.5);
    expect(p['status'], 'Unpaid');
    // Link: server name stored, flagged as a server value like a pull does.
    expect(p['customer'], 'CUST-0007');
    expect(p['customer__is_local'], 0);
    // Title field: its search column is refreshed the same way a pull does.
    expect(p['customer_name__norm'], isNotNull);
  });

  test('not opted in: only name / modified are written, as before', () async {
    await apply(serverResponse(), optIn: false);
    final p = await parent();
    expect(p['server_name'], 'SINV-0001');
    expect(p['sync_status'], 'synced');
    expect(p['invoice_no'], isNull);
    expect(p['grand_total'], isNull);
    expect(p['status'], 'Draft');
    expect(p['customer'], 'b3f1c2d4-0000-4000-8000-000000000001');
    expect(p['customer__is_local'], 1);
    final c1 = await child('c-1');
    expect(c1['server_name'], 'SII-1');
    expect(c1['amount'], isNull);
  });

  test(
    'child rows get their server fields (uuid and positional match)',
    () async {
      await apply(serverResponse());
      final c1 = await child('c-1');
      expect(c1['server_name'], 'SII-1');
      expect(c1['amount'], 200.0);
      final c2 = await child('c-2');
      expect(c2['server_name'], 'SII-2');
      expect(c2['amount'], 250.5);
      // System columns stay local: server idx is 1-based, local is 0-based.
      expect(c1['idx'], 0);
      expect(c2['idx'], 1);
      expect(c2['mobile_uuid'], 'c-2');
    },
  );

  test('a local re-edit queued during the push is not overwritten', () async {
    // The user saved again while the INSERT was in flight: a second outbox
    // row exists, so the local row holds edits newer than what was sent.
    await outbox.insertPending(
      doctype: 'Sales Invoice',
      mobileUuid: 'u-si',
      operation: OutboxOperation.update,
    );
    await db.update('docs__sales_invoice', {
      'status': 'Edited locally',
    }, where: "mobile_uuid = 'u-si'");
    await db.update('docs__si_item', {
      'amount': 999.0,
    }, where: "mobile_uuid = 'c-1'");

    await apply(serverResponse());

    final p = await parent();
    // Identity is still recorded so the follow-up UPDATE can address it.
    expect(p['server_name'], 'SINV-0001');
    expect(p['sync_status'], 'dirty');
    expect(p['status'], 'Edited locally');
    expect(p['invoice_no'], isNull);
    expect(p['customer__is_local'], 1);
    final c1 = await child('c-1');
    expect(c1['server_name'], 'SII-1');
    expect(c1['amount'], 999.0);
  });

  test(
    'unknown fields, missing columns and system columns are ignored',
    () async {
      final response = serverResponse()
        // Not a field of the local meta at all.
        ..['server_only_field'] = 'x'
        // In meta, but the local table has no column for it.
        ..['remarks'] = 'Checked by field officer'
        // A value SQLite cannot bind; skipped, not a rollback.
        ..['payload_json'] = {'k': 'v'}
        // System / sync columns the server may echo; the device owns these.
        ..['mobile_uuid'] = 'someone-else'
        ..['sync_status'] = 'conflict'
        ..['local_modified'] = 42;
      (response['items'] as List).first['parent_uuid'] = 'other-parent';
      (response['items'] as List).first['unknown_child_field'] = 'x';

      await apply(response);

      final p = await parent();
      expect(p['mobile_uuid'], 'u-si');
      expect(p['sync_status'], 'synced');
      expect(p['local_modified'], 1);
      expect(p['payload_json'], isNull);
      expect(p.containsKey('remarks'), isFalse);
      expect(p['invoice_no'], 'INV-2026-0001');
      final c1 = await child('c-1');
      expect(c1['parent_uuid'], 'u-si');
      expect(c1['amount'], 200.0);
      // Outbox row consumed: the writeback committed.
      expect(await outbox.findByState(OutboxState.pending), isEmpty);
    },
  );

  test('omitted keys keep local values; an explicit null is written', () async {
    await apply({
      'name': 'SINV-0001',
      'modified': '2026-02-01 10:00:00',
      'customer_name': null,
      // `status` and `customer` omitted: a lean response.
    });
    final p = await parent();
    expect(p['customer_name'], isNull);
    expect(p['status'], 'Draft');
    expect(p['customer'], 'b3f1c2d4-0000-4000-8000-000000000001');
  });

  group('PushEngine writeBackDoctypes', () {
    // The Link target in the seed row is a local uuid with no server row,
    // which would block the push upstream; point it at a server name.
    setUp(() async {
      await db.update('docs__sales_invoice', {
        'customer': 'CUST-0007',
        'customer__is_local': 0,
      });
    });

    PushEngine engine(Set<String> writeBackDoctypes) => PushEngine(
      db: db,
      outboxDao: outbox,
      attachmentDao: PendingAttachmentDao(db),
      metaDao: DoctypeMetaDao(db),
      pool: ConcurrencyPool(maxConcurrent: 2),
      notifier: SyncStateNotifier(),
      idempotencyStrategy: IdempotencyStrategy(serverHasDedupHook: false),
      metaResolver: (dt) async => parentMeta,
      childMetaResolver: (dt) async => childMeta,
      send: (method, payload, serverName) async => serverResponse(),
      serverFetcher: (_, _) async => throw StateError('not expected'),
      resolveServerName: (_, _) async => null,
      attachmentUploader:
          (file, {doctype, docname, fileName, isPrivate = true}) =>
              throw UnimplementedError(),
      writeBackDoctypes: writeBackDoctypes,
      attachmentBackoff: const [Duration.zero],
      networkBackoff: const [Duration.zero],
    );

    test('listed doctype: push response fields land locally', () async {
      await engine({'Sales Invoice'}).runOnce();
      final p = await parent();
      expect(p['sync_status'], 'synced');
      expect(p['invoice_no'], 'INV-2026-0001');
      expect(p['status'], 'Unpaid');
      expect((await child('c-2'))['amount'], 250.5);
    });

    test('unlisted doctype: unchanged behaviour', () async {
      await engine({'Some Other Doctype'}).runOnce();
      final p = await parent();
      expect(p['sync_status'], 'synced');
      expect(p['server_name'], 'SINV-0001');
      expect(p['invoice_no'], isNull);
      expect(p['status'], 'Draft');
      expect((await child('c-2'))['amount'], isNull);
    });
  });
}
