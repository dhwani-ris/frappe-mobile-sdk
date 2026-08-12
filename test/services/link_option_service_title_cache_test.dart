import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/daos/doctype_meta_dao.dart';
import 'package:frappe_mobile_sdk/src/database/schema/parent_schema.dart';
import 'package:frappe_mobile_sdk/src/database/schema/system_tables.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/query/unified_resolver.dart';
import 'package:frappe_mobile_sdk/src/services/link_option_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DocField f(String n, String t, {String? options}) =>
    DocField(fieldname: n, fieldtype: t, label: n, options: options);

/// `getLinkTitle` resolves ONE Link value to its display title. It was removed
/// once for being an N+1 plus an unbounded, never-invalidated cache, and
/// restored because its stated replacement — the `<field>__display` companion
/// `LinkDecorator.decorateBatch` adds — is produced ONLY for parent rows read
/// through the resolver. Child-table rows come from `mergeChildRowsIntoData`,
/// which copies raw SQLite columns and never decorates, so child Link cells
/// have no other title path.
///
/// These tests pin the two bounds that make the restoration safe: single-flight
/// dedupe (kills the N+1) and an LRU cap (kills the unbounded growth). Cache
/// hits are detected by counting metaResolver invocations — `_resolveLinkTitle`
/// calls it exactly once per real resolve, so a hit means the count is flat.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late UnifiedResolver resolver;
  late DocTypeMeta m;
  late int metaCalls;

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
    m = DocTypeMeta(
      name: 'Customer',
      titleField: 'customer_name',
      fields: [f('customer_name', 'Data')],
    );
    for (final s in buildParentSchemaDDL(m, tableName: 'docs__customer')) {
      await db.execute(s);
    }
    await db.insert('doctype_meta', {
      'doctype': 'Customer',
      'metaJson': jsonEncode(m.toJson()),
      'isMobileForm': 0,
      'table_name': 'docs__customer',
    });
    // A synced row: identified by server_name.
    await db.insert('docs__customer', {
      'mobile_uuid': 'u1',
      'server_name': 'CUST-1',
      'sync_status': 'synced',
      'local_modified': 1,
      'customer_name': 'ACME Industries',
      'customer_name__norm': 'acme industries',
    });
    // A device-created row that has not pushed: identified by mobile_uuid,
    // because `name` is not a local column.
    await db.insert('docs__customer', {
      'mobile_uuid': 'local-uuid-2',
      'sync_status': 'dirty',
      'local_modified': 2,
      'customer_name': 'Pending Inc',
      'customer_name__norm': 'pending inc',
    });
    resolver = UnifiedResolver(
      db: db,
      metaDao: DoctypeMetaDao(db),
      isOnline: () => false,
      backgroundFetch: (_, _) async {},
      metaResolver: (dt) async => m,
    );
    metaCalls = 0;
  });

  tearDown(() async => db.close());

  LinkOptionService makeSvc() => LinkOptionService(resolver, (dt) async {
    metaCalls++;
    return m;
  });

  group('getLinkTitle — resolution', () {
    test('resolves a synced row via server_name', () async {
      final svc = makeSvc();
      expect(await svc.getLinkTitle('Customer', 'CUST-1'), 'ACME Industries');
    });

    test('resolves a device-created row via mobile_uuid', () async {
      final svc = makeSvc();
      expect(
        await svc.getLinkTitle('Customer', 'local-uuid-2'),
        'Pending Inc',
        reason:
            'a Link value may point at a row created on this device that has '
            'not pushed yet, so mobile_uuid must be matched too',
      );
    });

    test('empty name short-circuits without touching the resolver', () async {
      final svc = makeSvc();
      expect(await svc.getLinkTitle('Customer', ''), isNull);
      expect(metaCalls, 0);
    });

    test('unresolvable value returns null', () async {
      final svc = makeSvc();
      expect(await svc.getLinkTitle('Customer', 'NOPE-999'), isNull);
    });
  });

  group('getLinkTitle — caching bounds', () {
    test('a successful title is cached (second read does not re-resolve)', () {
      return (() async {
        final svc = makeSvc();
        expect(await svc.getLinkTitle('Customer', 'CUST-1'), 'ACME Industries');
        expect(metaCalls, 1);
        expect(await svc.getLinkTitle('Customer', 'CUST-1'), 'ACME Industries');
        expect(metaCalls, 1, reason: 'second read must be a cache hit');
      })();
    });

    test('a MISS is not cached — it stays retryable', () async {
      final svc = makeSvc();
      expect(await svc.getLinkTitle('Customer', 'CUST-2'), isNull);
      expect(metaCalls, 1);

      // The target doctype may simply not have pulled yet; once the row
      // arrives the same lookup must succeed rather than serving a cached null.
      await db.insert('docs__customer', {
        'mobile_uuid': 'u3',
        'server_name': 'CUST-2',
        'sync_status': 'synced',
        'local_modified': 3,
        'customer_name': 'Late Arrival',
        'customer_name__norm': 'late arrival',
      });
      expect(await svc.getLinkTitle('Customer', 'CUST-2'), 'Late Arrival');
      expect(metaCalls, 2, reason: 'a miss must not have been cached');
    });

    test(
      'concurrent reads of the SAME value share ONE resolve (single-flight)',
      () async {
        final svc = makeSvc();
        // The N+1 this replaces: N grid cells pointing at the same target each
        // firing their own resolve.
        final results = await Future.wait(
          List.generate(8, (_) => svc.getLinkTitle('Customer', 'CUST-1')),
        );
        expect(results, everyElement('ACME Industries'));
        expect(
          metaCalls,
          1,
          reason:
              '8 concurrent reads of one key must trigger exactly 1 resolve',
        );
      },
    );

    test('cache is LRU-bounded — the oldest entry is evicted', () async {
      final svc = makeSvc();
      // Fill past the 500-entry cap with distinct, cacheable titles (a title
      // equal to the name is deliberately not cached, so each label differs).
      for (var i = 0; i < 520; i++) {
        await db.insert('docs__customer', {
          'mobile_uuid': 'bulk-$i',
          'server_name': 'BULK-$i',
          'sync_status': 'synced',
          'local_modified': 100 + i,
          'customer_name': 'Bulk Customer $i',
          'customer_name__norm': 'bulk customer $i',
        });
      }
      expect(await svc.getLinkTitle('Customer', 'BULK-0'), 'Bulk Customer 0');
      final afterFirst = metaCalls;

      for (var i = 1; i < 520; i++) {
        await svc.getLinkTitle('Customer', 'BULK-$i');
      }
      final afterFill = metaCalls;
      expect(afterFill, afterFirst + 519);

      // BULK-0 was the oldest and must have been evicted, so reading it again
      // re-resolves instead of hitting the cache.
      expect(await svc.getLinkTitle('Customer', 'BULK-0'), 'Bulk Customer 0');
      expect(
        metaCalls,
        afterFill + 1,
        reason: 'the oldest entry must have been evicted past the LRU cap',
      );

      // A recently-read key is still cached — proving eviction is bounded to
      // the oldest, not a wholesale clear.
      final before = metaCalls;
      expect(
        await svc.getLinkTitle('Customer', 'BULK-519'),
        'Bulk Customer 519',
      );
      expect(metaCalls, before, reason: 'a recent entry must still be cached');
    });
  });
}
