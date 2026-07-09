// Regression coverage for the reactive permission-skip closure prune.
//
// `PullEngine._runDoctype` must invoke `onPermissionDenied` ONLY when a
// per-doctype pull fails with a genuine HTTP 403 (`FrappeException` whose
// `statusCode == 403`). Every other failure mode — 5xx, timeout,
// SocketException, or a sqflite "no such table" DatabaseException — must
// stay silently retryable: the callback must NOT fire for those, otherwise
// a transient outage would get permanently pruned from future closure
// pulls exactly like a real permission denial.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/api/exceptions.dart';
import 'package:frappe_mobile_sdk/src/concurrency/concurrency_pool.dart';
import 'package:frappe_mobile_sdk/src/database/daos/doctype_meta_dao.dart';
import 'package:frappe_mobile_sdk/src/database/daos/outbox_dao.dart';
import 'package:frappe_mobile_sdk/src/database/schema/parent_schema.dart';
import 'package:frappe_mobile_sdk/src/database/schema/system_tables.dart';
import 'package:frappe_mobile_sdk/src/models/closure_result.dart';
import 'package:frappe_mobile_sdk/src/models/dep_graph.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/sync/pull_engine.dart';
import 'package:frappe_mobile_sdk/src/sync/pull_page_fetcher.dart';
import 'package:frappe_mobile_sdk/src/sync/sync_state_notifier.dart';
import 'package:sqflite_common/src/exception.dart' show SqfliteDatabaseException;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DocField f(String n, String t, {String? options}) =>
    DocField(fieldname: n, fieldtype: t, label: n, options: options);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late DoctypeMetaDao metaDao;

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

    final meta = DocTypeMeta(
      name: 'Customer',
      fields: [f('customer_name', 'Data')],
    );
    for (final s in buildParentSchemaDDL(meta, tableName: 'docs__customer')) {
      await db.execute(s);
    }
    await db.insert('doctype_meta', {
      'doctype': 'Customer',
      'metaJson': '{}',
      'isMobileForm': 0,
      'table_name': 'docs__customer',
    });

    metaDao = DoctypeMetaDao(db);
  });

  tearDown(() async => db.close());

  ClosureResult customerClosure() => const ClosureResult(
        doctypes: ['Customer'],
        graph: {
          'Customer': DepGraph(
            doctype: 'Customer',
            tier: 0,
            outgoing: [],
            incoming: [],
          ),
        },
        childDoctypes: {},
        warnings: [],
      );

  PullEngine buildEngine({
    required PullPageFetcher fetcher,
    required List<String> recordedSkips,
  }) {
    return PullEngine(
      db: db,
      metaDao: metaDao,
      outboxDao: OutboxDao(db),
      pool: ConcurrencyPool(maxConcurrent: 2),
      fetcher: fetcher,
      pageSize: 500,
      notifier: SyncStateNotifier(),
      metaResolver: (dt) async =>
          DocTypeMeta(name: dt, fields: [f('customer_name', 'Data')]),
      onPermissionDenied: (doctype) async {
        recordedSkips.add(doctype);
      },
    );
  }

  test(
    '403 (FrappeException.statusCode == 403) records the doctype via onPermissionDenied',
    () async {
      final recordedSkips = <String>[];
      final fetcher = PullPageFetcher(
        listHttp: (doctype, params) async {
          throw FrappeException('Not permitted', 403);
        },
      );
      final engine = buildEngine(fetcher: fetcher, recordedSkips: recordedSkips);

      await engine.run(customerClosure());

      expect(
        recordedSkips,
        ['Customer'],
        reason: 'a genuine 403 must be recorded exactly once',
      );
      expect(
        await metaDao.getLastOkCursor('Customer'),
        isNull,
        reason: 'cursor must not advance on a failed pull',
      );
    },
  );

  test(
    'ApiException with statusCode 403 also records — subclass of FrappeException',
    () async {
      final recordedSkips = <String>[];
      final fetcher = PullPageFetcher(
        listHttp: (doctype, params) async {
          throw ApiException('Forbidden', 403, {'detail': 'no read perm'});
        },
      );
      final engine = buildEngine(fetcher: fetcher, recordedSkips: recordedSkips);

      await engine.run(customerClosure());

      expect(recordedSkips, ['Customer']);
    },
  );

  test(
    '500 (server error) does NOT record — must stay retryable',
    () async {
      final recordedSkips = <String>[];
      final fetcher = PullPageFetcher(
        listHttp: (doctype, params) async {
          throw ApiException('Internal Server Error', 500);
        },
      );
      final engine = buildEngine(fetcher: fetcher, recordedSkips: recordedSkips);

      await engine.run(customerClosure());

      expect(recordedSkips, isEmpty);
    },
  );

  test(
    'a timeout (TimeoutException) does NOT record — must stay retryable',
    () async {
      final recordedSkips = <String>[];
      final fetcher = PullPageFetcher(
        listHttp: (doctype, params) async {
          throw TimeoutException('request timed out');
        },
      );
      final engine = buildEngine(fetcher: fetcher, recordedSkips: recordedSkips);

      await engine.run(customerClosure());

      expect(recordedSkips, isEmpty);
    },
  );

  test(
    'a SocketException does NOT record — must stay retryable',
    () async {
      final recordedSkips = <String>[];
      final fetcher = PullPageFetcher(
        listHttp: (doctype, params) async {
          throw const SocketException('Connection refused');
        },
      );
      final engine = buildEngine(fetcher: fetcher, recordedSkips: recordedSkips);

      await engine.run(customerClosure());

      expect(recordedSkips, isEmpty);
    },
  );

  test(
    'a "no such table" DatabaseException does NOT record — must stay retryable',
    () async {
      final recordedSkips = <String>[];
      final fetcher = PullPageFetcher(
        listHttp: (doctype, params) async {
          throw SqfliteDatabaseException(
            'no such table: docs__customer',
            null,
          );
        },
      );
      final engine = buildEngine(fetcher: fetcher, recordedSkips: recordedSkips);

      await engine.run(customerClosure());

      expect(recordedSkips, isEmpty);
    },
  );

  test(
    'a plain non-FrappeException with no statusCode does NOT record',
    () async {
      final recordedSkips = <String>[];
      final fetcher = PullPageFetcher(
        listHttp: (doctype, params) async {
          throw Exception('boom');
        },
      );
      final engine = buildEngine(fetcher: fetcher, recordedSkips: recordedSkips);

      await engine.run(customerClosure());

      expect(recordedSkips, isEmpty);
    },
  );

  test(
    'onPermissionDenied throwing does not crash the pull (caught + logged)',
    () async {
      final fetcher = PullPageFetcher(
        listHttp: (doctype, params) async {
          throw FrappeException('Not permitted', 403);
        },
      );
      final engine = PullEngine(
        db: db,
        metaDao: metaDao,
        outboxDao: OutboxDao(db),
        pool: ConcurrencyPool(maxConcurrent: 2),
        fetcher: fetcher,
        pageSize: 500,
        notifier: SyncStateNotifier(),
        metaResolver: (dt) async =>
            DocTypeMeta(name: dt, fields: [f('customer_name', 'Data')]),
        onPermissionDenied: (doctype) async {
          throw Exception('DB write failed');
        },
      );

      // Must complete without throwing/propagating the callback's error.
      await engine.run(customerClosure());
    },
  );

  test(
    'no onPermissionDenied wired (null) — a 403 does not crash the pull',
    () async {
      final fetcher = PullPageFetcher(
        listHttp: (doctype, params) async {
          throw FrappeException('Not permitted', 403);
        },
      );
      final engine = PullEngine(
        db: db,
        metaDao: metaDao,
        outboxDao: OutboxDao(db),
        pool: ConcurrencyPool(maxConcurrent: 2),
        fetcher: fetcher,
        pageSize: 500,
        notifier: SyncStateNotifier(),
        metaResolver: (dt) async =>
            DocTypeMeta(name: dt, fields: [f('customer_name', 'Data')]),
      );

      await engine.run(customerClosure());
    },
  );
}
