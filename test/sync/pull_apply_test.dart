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
      name: 'Sales Order',
      titleField: 'customer',
      fields: [
        f('customer', 'Link', options: 'Customer'),
        f('items', 'Table', options: 'Sales Order Item'),
      ],
    );
    childMeta = DocTypeMeta(
      name: 'Sales Order Item',
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
      tableName: 'docs__sales_order_item',
    )) {
      await db.execute(s);
    }
  });

  tearDown(() async => db.close());

  test('child Link fields receive __is_local=0 on pull', () async {
    // Uses a child meta with a Link field to exercise the
    // `childRow['${cn}__is_local'] = 0` branch inside applyPageInTxn.
    final childWithLink = DocTypeMeta(
      name: 'SO Line',
      isTable: true,
      fields: [
        f('product', 'Link', options: 'Product'),
        f('qty', 'Int'),
      ],
    );
    for (final s in buildChildSchemaDDL(
      childWithLink,
      tableName: 'docs__so_line',
    )) {
      await db.execute(s);
    }
    final parentWithLink = DocTypeMeta(
      name: 'SO With Link',
      fields: [f('lines', 'Table', options: 'SO Line')],
    );
    for (final s in buildParentSchemaDDL(
      parentWithLink,
      tableName: 'docs__so_with_link',
    )) {
      await db.execute(s);
    }
    await PullApply.applyPage(
      db: db,
      parentMeta: parentWithLink,
      parentTable: 'docs__so_with_link',
      childMetasByFieldname: {
        'lines': PullApplyChildInfo('SO Line', childWithLink),
      },
      rows: [
        {
          'name': 'SOL-1',
          'modified': '2026-01-01',
          'lines': [
            {'product': 'PROD-001', 'qty': 5},
          ],
        },
      ],
    );
    final c = await db.query('docs__so_line');
    expect(c.length, 1);
    expect(c.first['product'], 'PROD-001');
    expect(
      c.first['product__is_local'],
      0,
      reason: 'pulled Link fields must be marked as server values',
    );
  });

  test('UPSERT inserts new row with generated mobile_uuid', () async {
    await PullApply.applyPage(
      db: db,
      parentMeta: parentMeta,
      parentTable: 'docs__sales_order',
      childMetasByFieldname: {
        'items': PullApplyChildInfo('Sales Order Item', childMeta),
      },
      rows: [
        {
          'name': 'SO-1',
          'modified': '2026-01-01 00:00:00',
          'customer': 'CUST-1',
          'items': [
            {'item_code': 'A', 'qty': 1},
          ],
        },
      ],
    );
    final p = await db.query('docs__sales_order');
    expect(p.length, 1);
    expect(p.first['server_name'], 'SO-1');
    expect(p.first['mobile_uuid'], isNotNull);
    expect(p.first['sync_status'], 'synced');
    expect(p.first['customer'], 'CUST-1');
    final c = await db.query('docs__sales_order_item');
    expect(c.length, 1);
    expect(c.first['item_code'], 'A');
  });

  test('UPSERT updates existing, preserves mobile_uuid', () async {
    await db.insert('docs__sales_order', {
      'mobile_uuid': 'u1',
      'server_name': 'SO-1',
      'sync_status': 'synced',
      'local_modified': 1,
      'customer': 'OLD',
    });
    await PullApply.applyPage(
      db: db,
      parentMeta: parentMeta,
      parentTable: 'docs__sales_order',
      childMetasByFieldname: const {},
      rows: [
        {'name': 'SO-1', 'modified': '2026-01-02', 'customer': 'NEW'},
      ],
    );
    final p = await db.query('docs__sales_order');
    expect(p.length, 1);
    expect(p.first['mobile_uuid'], 'u1');
    expect(p.first['customer'], 'NEW');
  });

  test('marks conflict when local is dirty', () async {
    await db.insert('docs__sales_order', {
      'mobile_uuid': 'u1',
      'server_name': 'SO-1',
      'sync_status': 'dirty',
      'local_modified': 1,
      'customer': 'LOCAL_EDIT',
    });
    await PullApply.applyPage(
      db: db,
      parentMeta: parentMeta,
      parentTable: 'docs__sales_order',
      childMetasByFieldname: const {},
      rows: [
        {'name': 'SO-1', 'modified': '2026-02-01', 'customer': 'SERVER_NEW'},
      ],
    );
    final p = await db.query('docs__sales_order');
    expect(p.first['sync_status'], 'conflict');
    expect(
      p.first['customer'],
      'LOCAL_EDIT',
      reason: 'local dirty payload preserved',
    );
  });

  // AC3 / C3: empirical pin for the child-wipe gate. When the parent's
  // local sync_status is in (dirty|failed|conflict|blocked), the pull MUST
  // NOT touch child rows — children inherit the parent's status and so
  // share its "locally edited, do not overwrite" treatment.
  test(
    'dirty parent shields child rows from pull-apply wipe (C3 regression)',
    () async {
      // Local state: parent dirty, two locally-edited children.
      await db.insert('docs__sales_order', {
        'mobile_uuid': 'u1',
        'server_name': 'SO-1',
        'sync_status': 'dirty',
        'local_modified': 1,
        'modified': '2026-01-01 00:00:00',
        'customer': 'LOCAL_EDIT',
      });
      await db.insert('docs__sales_order_item', {
        'mobile_uuid': 'c-local-1',
        'parent_uuid': 'u1',
        'parent_doctype': 'Sales Order',
        'parentfield': 'items',
        'idx': 0,
        'item_code': 'LOCAL-A',
        'qty': 7,
      });
      await db.insert('docs__sales_order_item', {
        'mobile_uuid': 'c-local-2',
        'parent_uuid': 'u1',
        'parent_doctype': 'Sales Order',
        'parentfield': 'items',
        'idx': 1,
        'item_code': 'LOCAL-B',
        'qty': 8,
      });

      // Server is ahead and disagrees on every cell.
      await PullApply.applyPage(
        db: db,
        parentMeta: parentMeta,
        parentTable: 'docs__sales_order',
        childMetasByFieldname: {
          'items': PullApplyChildInfo('Sales Order Item', childMeta),
        },
        rows: [
          {
            'name': 'SO-1',
            'modified': '2026-02-01 00:00:00',
            'customer': 'SERVER_NEW',
            'items': [
              {'item_code': 'SERVER-X', 'qty': 99},
              {'item_code': 'SERVER-Y', 'qty': 88},
              {'item_code': 'SERVER-Z', 'qty': 77},
            ],
          },
        ],
      );

      // Parent flips to conflict; local payload preserved.
      final p = await db.query('docs__sales_order');
      expect(p.first['sync_status'], 'conflict');
      expect(p.first['customer'], 'LOCAL_EDIT');

      // Children are untouched — same uuids, same item_codes, same count.
      final c = await db.query('docs__sales_order_item', orderBy: 'idx ASC');
      expect(c.length, 2);
      expect(c[0]['mobile_uuid'], 'c-local-1');
      expect(c[0]['item_code'], 'LOCAL-A');
      expect(c[0]['qty'], 7);
      expect(c[1]['mobile_uuid'], 'c-local-2');
      expect(c[1]['item_code'], 'LOCAL-B');
      expect(c[1]['qty'], 8);
    },
  );

  // Symmetric variant: same protection must hold for failed / blocked
  // statuses. Parameterized inline so adding a new locally-dirty status
  // value to `_locallyDirtyStatuses` is one line here.
  for (final status in const ['failed', 'conflict', 'blocked']) {
    test('$status parent also shields children from pull wipe', () async {
      await db.insert('docs__sales_order', {
        'mobile_uuid': 'u1',
        'server_name': 'SO-1',
        'sync_status': status,
        'local_modified': 1,
        'modified': '2026-01-01 00:00:00',
      });
      await db.insert('docs__sales_order_item', {
        'mobile_uuid': 'c-local-1',
        'parent_uuid': 'u1',
        'parent_doctype': 'Sales Order',
        'parentfield': 'items',
        'idx': 0,
        'item_code': 'LOCAL',
        'qty': 1,
      });
      await PullApply.applyPage(
        db: db,
        parentMeta: parentMeta,
        parentTable: 'docs__sales_order',
        childMetasByFieldname: {
          'items': PullApplyChildInfo('Sales Order Item', childMeta),
        },
        rows: [
          {
            'name': 'SO-1',
            'modified': '2026-03-01 00:00:00',
            'items': [
              {'item_code': 'SERVER', 'qty': 100},
            ],
          },
        ],
      );
      final c = await db.query('docs__sales_order_item');
      expect(c.length, 1, reason: 'children survived pull when parent=$status');
      expect(c.first['item_code'], 'LOCAL');
    });
  }

  test('children fully replaced on re-pull', () async {
    await db.insert('docs__sales_order', {
      'mobile_uuid': 'u1',
      'server_name': 'SO-1',
      'sync_status': 'synced',
      'local_modified': 1,
    });
    await db.insert('docs__sales_order_item', {
      'mobile_uuid': 'c1',
      'parent_uuid': 'u1',
      'parent_doctype': 'Sales Order',
      'parentfield': 'items',
      'idx': 0,
      'item_code': 'OLD-A',
      'qty': 1,
    });
    await db.insert('docs__sales_order_item', {
      'mobile_uuid': 'c2',
      'parent_uuid': 'u1',
      'parent_doctype': 'Sales Order',
      'parentfield': 'items',
      'idx': 1,
      'item_code': 'OLD-B',
      'qty': 2,
    });

    await PullApply.applyPage(
      db: db,
      parentMeta: parentMeta,
      parentTable: 'docs__sales_order',
      childMetasByFieldname: {
        'items': PullApplyChildInfo('Sales Order Item', childMeta),
      },
      rows: [
        {
          'name': 'SO-1',
          'modified': '2026-02-01',
          'items': [
            {'item_code': 'NEW-X', 'qty': 9},
          ],
        },
      ],
    );
    final c = await db.query('docs__sales_order_item');
    expect(c.length, 1);
    expect(c.first['item_code'], 'NEW-X');
  });

  test('__norm populated on write for title_field + searchFields', () async {
    final m = DocTypeMeta(
      name: 'Customer',
      titleField: 'full_name',
      searchFields: ['email'],
      fields: [f('full_name', 'Data'), f('email', 'Data')],
    );
    for (final s in buildParentSchemaDDL(m, tableName: 'docs__customer')) {
      await db.execute(s);
    }
    await PullApply.applyPage(
      db: db,
      parentMeta: m,
      parentTable: 'docs__customer',
      childMetasByFieldname: const {},
      rows: [
        {
          'name': 'C-1',
          'modified': '2026-01-01',
          'full_name': 'Café Ankıt',
          'email': 'A@B.COM',
        },
      ],
    );
    final row = await db.query('docs__customer');
    expect(row.first['full_name__norm'], 'cafe ankit');
    expect(row.first['email__norm'], 'a@b.com');
  });

  test('Link fields receive __is_local=0 (server values)', () async {
    await PullApply.applyPage(
      db: db,
      parentMeta: parentMeta,
      parentTable: 'docs__sales_order',
      childMetasByFieldname: const {},
      rows: [
        {'name': 'SO-Z', 'modified': '2026-01-01', 'customer': 'CUST-Z'},
      ],
    );
    final p = await db.query('docs__sales_order');
    expect(p.first['customer__is_local'], 0);
  });

  // Regression: doctypes that expose `mobile_uuid` as a meta field (used for
  // L2 idempotency on the server) used to have their generated PK overwritten
  // by the server's empty string, causing all but the first row to fail
  // with `UNIQUE constraint failed: mobile_uuid` -- silently swallowed by the
  // best-effort catch in OfflineRepository._writeToPerDoctypeTable.
  test('meta-defined mobile_uuid does NOT overwrite generated PK', () async {
    final m = DocTypeMeta(
      name: 'Employee',
      fields: [
        f('emp_id', 'Data'),
        f('mobile_uuid', 'Data'),
        f('modified', 'Datetime'),
        f('docstatus', 'Int'),
      ],
    );
    for (final s in buildParentSchemaDDL(m, tableName: 'docs__employee')) {
      await db.execute(s);
    }
    await PullApply.applyPage(
      db: db,
      parentMeta: m,
      parentTable: 'docs__employee',
      childMetasByFieldname: const {},
      rows: [
        // Three rows the server returns with empty/null mobile_uuid -- a
        // non-deduped write would PK-collide on the second one.
        {
          'name': 'EMP-1',
          'modified': '2026-01-01',
          'emp_id': 'E1',
          'mobile_uuid': '',
          'docstatus': 0,
        },
        {
          'name': 'EMP-2',
          'modified': '2026-01-02',
          'emp_id': 'E2',
          'mobile_uuid': '',
          'docstatus': 1,
        },
        {
          'name': 'EMP-3',
          'modified': '2026-01-03',
          'emp_id': 'E3',
          'mobile_uuid': null,
          'docstatus': 0,
        },
      ],
    );
    final rows = await db.query('docs__employee', orderBy: 'server_name');
    expect(rows.length, 3, reason: 'all three rows must land');
    final uuids = rows.map((r) => r['mobile_uuid']).toSet();
    expect(uuids.length, 3, reason: 'each row needs a distinct generated UUID');
    for (final u in uuids) {
      expect(u, isA<String>());
      expect((u as String).isNotEmpty, isTrue);
    }
    // docstatus IS still mirrored from server data (system column with sane
    // default; meta-loop value passes through but does not break PK).
    expect(rows.firstWhere((r) => r['server_name'] == 'EMP-2')['docstatus'], 1);
  });

  test(
    'parseFrappeUtcStringForTest normalizes tz-naive Frappe timestamps to UTC',
    () {
      // Frappe returns "YYYY-MM-DD HH:MM:SS.ffffff" with no timezone.
      // Without normalization, DateTime.tryParse interprets these as local
      // time — brittle across DST and tz changes. The helper appends `Z`
      // unless an offset is already present.
      expect(parseFrappeUtcStringForTest('2024-01-01 10:00:00'), endsWith('Z'));
      expect(
        parseFrappeUtcStringForTest('2024-01-01 10:00:00.500000'),
        endsWith('Z'),
      );
      expect(
        parseFrappeUtcStringForTest('2024-01-01 10:00:00Z'),
        equals('2024-01-01 10:00:00Z'),
      );
      expect(
        parseFrappeUtcStringForTest('2024-01-01T10:00:00+05:30'),
        contains('+05:30'),
      );
      expect(
        parseFrappeUtcStringForTest('2024-01-01T10:00:00-08:00'),
        contains('-08:00'),
      );
      expect(parseFrappeUtcStringForTest(null), isNull);
      expect(parseFrappeUtcStringForTest(''), isNull);
      // Date-only strings stay as-is — Dart's DateTime.tryParse rejects
      // `YYYY-MM-DDZ`, so we don't append the suffix when there's no time
      // component. Comparison still works because two such strings parse
      // with the same offset.
      expect(parseFrappeUtcStringForTest('2024-01-01'), '2024-01-01');
      expect(
        DateTime.tryParse(parseFrappeUtcStringForTest('2024-01-01')!),
        isNotNull,
      );
      expect(
        DateTime.tryParse(parseFrappeUtcStringForTest('2024-01-01 10:00:00')!),
        isNotNull,
      );
    },
  );

  test('Password fields are not persisted to the local mirror', () async {
    // Schema generation already excludes Password columns; PullApply
    // additionally skips them via `sqliteColumnTypeFor(type) == null`.
    // This test pins the contract: even when the server response carries
    // a Password value, no `password` column is created and no write is
    // attempted against it.
    final m = DocTypeMeta(
      name: 'Vendor',
      fields: [f('vendor_name', 'Data'), f('api_secret', 'Password')],
    );
    for (final s in buildParentSchemaDDL(m, tableName: 'docs__vendor')) {
      await db.execute(s);
    }
    await PullApply.applyPage(
      db: db,
      parentMeta: m,
      parentTable: 'docs__vendor',
      childMetasByFieldname: const {},
      rows: [
        {
          'name': 'V-001',
          'vendor_name': 'Acme',
          'api_secret': 'leaked-if-stored',
          'modified': '2026-01-01',
        },
      ],
    );
    final cols = (await db.rawQuery(
      'PRAGMA table_info(docs__vendor)',
    )).map((r) => r['name'] as String).toSet();
    expect(
      cols.contains('api_secret'),
      isFalse,
      reason: 'Password columns must never be created',
    );
    final rows = await db.query('docs__vendor');
    expect(rows.length, 1);
    expect(rows.first['vendor_name'], 'Acme');
    expect(rows.first.containsKey('api_secret'), isFalse);
  });

  test(
    'child mobile_uuid is preserved across re-pull (regression: orphan Link)',
    () async {
      // Server returns the parent and one child with explicit mobile_uuid
      // (mobile_control's Custom Field round-trips local identity).
      const childUuid = 'fm-uuid-stable-1234';
      Map<String, dynamic> page() => {
        'name': 'SO-1',
        'modified': '2026-01-01 00:00:00',
        'customer': 'CUST-1',
        'items': [
          {
            'mobile_uuid': childUuid,
            'name': 'SO-1-IT-1',
            'item_code': 'A',
            'qty': 1,
          },
        ],
      };

      await PullApply.applyPage(
        db: db,
        parentMeta: parentMeta,
        parentTable: 'docs__sales_order',
        childMetasByFieldname: {
          'items': PullApplyChildInfo('Sales Order Item', childMeta),
        },
        rows: [page()],
      );
      final firstChildren = await db.query('docs__sales_order_item');
      expect(firstChildren.length, 1);
      expect(
        firstChildren.first['mobile_uuid'],
        childUuid,
        reason: 'first apply must adopt the server-supplied mobile_uuid',
      );

      // Re-pull (e.g. SyncController.syncNow's deferred re-pull path).
      // The child's mobile_uuid must NOT change — outbound Link fields on
      // other docs (e.g. Plus MIS Learner.learner_name) reference it.
      await PullApply.applyPage(
        db: db,
        parentMeta: parentMeta,
        parentTable: 'docs__sales_order',
        childMetasByFieldname: {
          'items': PullApplyChildInfo('Sales Order Item', childMeta),
        },
        rows: [page()],
      );
      final secondChildren = await db.query('docs__sales_order_item');
      expect(secondChildren.length, 1);
      expect(
        secondChildren.first['mobile_uuid'],
        childUuid,
        reason:
            're-pull must keep the same mobile_uuid; otherwise any Link field '
            'pointing at the child becomes a permanent orphan',
      );
    },
  );

  test('child mobile_uuid falls back to v4 when server omits it', () async {
    // Doctypes outside mobile_control workspace do not have the Custom
    // Field, so `as_dict()` won't include `mobile_uuid`. Guarantee a
    // valid uuid is still generated (length matches v4 36-char form).
    await PullApply.applyPage(
      db: db,
      parentMeta: parentMeta,
      parentTable: 'docs__sales_order',
      childMetasByFieldname: {
        'items': PullApplyChildInfo('Sales Order Item', childMeta),
      },
      rows: [
        {
          'name': 'SO-2',
          'modified': '2026-01-01 00:00:00',
          'customer': 'CUST-2',
          'items': [
            {'item_code': 'B', 'qty': 2},
          ],
        },
      ],
    );
    final children = await db.query('docs__sales_order_item');
    expect(children.length, 1);
    final uuid = children.first['mobile_uuid'] as String;
    expect(uuid.length, 36);
    expect(uuid.contains('-'), isTrue);
  });

  test(
    'preserves local child mobile_uuid by matching server_name on re-pull',
    () async {
      // Pull-after-push scenario: ResponseWriteback has stamped the
      // local child with `server_name`, then a re-pull arrives with
      // the same server_name but no echoed mobile_uuid (e.g. before
      // mobile_control adds the Custom Field to a child doctype).
      // Without server_name matching the row would be wiped and
      // re-inserted with a fresh v4, orphaning every cross-doc Link.
      const localChildUuid = 'local-fm-uuid-1';
      await db.insert('docs__sales_order', {
        'mobile_uuid': 'so-uuid-1',
        'server_name': 'SO-100',
        'sync_status': 'synced',
        'local_modified': 1,
        'customer': 'CUST',
      });
      await db.insert('docs__sales_order_item', {
        'mobile_uuid': localChildUuid,
        'server_name': 'SO-100-IT-1',
        'parent_uuid': 'so-uuid-1',
        'parent_doctype': 'Sales Order',
        'parentfield': 'items',
        'idx': 0,
        'item_code': 'A',
        'qty': 1,
      });

      await PullApply.applyPage(
        db: db,
        parentMeta: parentMeta,
        parentTable: 'docs__sales_order',
        childMetasByFieldname: {
          'items': PullApplyChildInfo('Sales Order Item', childMeta),
        },
        rows: [
          {
            'name': 'SO-100',
            'modified': '2026-01-02 00:00:00',
            'customer': 'CUST',
            'items': [
              // No 'mobile_uuid' key — server didn't echo it.
              {'name': 'SO-100-IT-1', 'item_code': 'A', 'qty': 1},
            ],
          },
        ],
      );
      final children = await db.query('docs__sales_order_item');
      expect(children.length, 1);
      expect(
        children.first['mobile_uuid'],
        localChildUuid,
        reason:
            'server_name match must preserve the local mobile_uuid '
            'so cross-doc Link references stay valid',
      );
    },
  );
}
