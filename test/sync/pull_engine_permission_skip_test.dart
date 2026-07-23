// Regression coverage for the reactive permission-skip closure prune,
// reworked for the ROUND-based callback API introduced by Fix 2.
//
// `PullEngine.run` now defers the skip/auth-event decision to the END of a
// pull round: it collects every doctype that hard-403'd (`FrappeException`
// whose `statusCode == 403`) into a round-local set and fires
// `onPermissionDeniedRound(Set<String>)` exactly ONCE per `run()`. Every
// other failure mode — 5xx, timeout, SocketException, a sqflite "no such
// table" DatabaseException, or a plain Exception — must leave that set
// EMPTY: the doctype stays silently retryable, exactly as before.
//
// A doctype that FULLY drains with a 200 fires `onDoctypePullOk(doctype)`
// so a previously-denied-then-granted doctype self-heals immediately.

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

  /// Builds an engine that records:
  ///  - [rounds]: every `denied403` Set handed to `onPermissionDeniedRound`
  ///    (fired exactly once per `run()`).
  ///  - [okCalls]: every doctype handed to `onDoctypePullOk`.
  PullEngine buildEngine({
    required PullPageFetcher fetcher,
    required List<Set<String>> rounds,
    List<String>? okCalls,
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
      onPermissionDeniedRound: (denied) async {
        rounds.add(Set<String>.from(denied));
      },
      onDoctypePullOk: (dt) async => okCalls?.add(dt),
    );
  }

  test(
    '403 (FrappeException.statusCode == 403) surfaces the doctype in the round set',
    () async {
      final rounds = <Set<String>>[];
      final fetcher = PullPageFetcher(
        listHttp: (doctype, params) async {
          throw FrappeException('Not permitted', 403);
        },
      );
      final engine = buildEngine(fetcher: fetcher, rounds: rounds);

      await engine.run(customerClosure());

      expect(
        rounds,
        hasLength(1),
        reason: 'onPermissionDeniedRound fires exactly once per run()',
      );
      expect(
        rounds.single,
        {'Customer'},
        reason: 'a genuine 403 must appear in the round denied-set',
      );
      expect(
        await metaDao.getLastOkCursor('Customer'),
        isNull,
        reason: 'cursor must not advance on a failed pull',
      );
    },
  );

  test(
    'ApiException with statusCode 403 also surfaces — subclass of FrappeException',
    () async {
      final rounds = <Set<String>>[];
      final fetcher = PullPageFetcher(
        listHttp: (doctype, params) async {
          throw ApiException('Forbidden', 403, {'detail': 'no read perm'});
        },
      );
      final engine = buildEngine(fetcher: fetcher, rounds: rounds);

      await engine.run(customerClosure());

      expect(rounds.single, {'Customer'});
    },
  );

  test(
    'AuthException with statusCode 403 also surfaces — real REST-layer 403',
    () async {
      // A real 403 from RestHelper is an AuthException (extends
      // FrappeException). The classifier is `e is FrappeException &&
      // statusCode == 403`, so this must be counted too.
      final rounds = <Set<String>>[];
      final fetcher = PullPageFetcher(
        listHttp: (doctype, params) async {
          throw AuthException('You do not have read permission', 403);
        },
      );
      final engine = buildEngine(fetcher: fetcher, rounds: rounds);

      await engine.run(customerClosure());

      expect(rounds.single, {'Customer'});
    },
  );

  test(
    '500 (server error) leaves the round set empty — must stay retryable',
    () async {
      final rounds = <Set<String>>[];
      final fetcher = PullPageFetcher(
        listHttp: (doctype, params) async {
          throw ApiException('Internal Server Error', 500);
        },
      );
      final engine = buildEngine(fetcher: fetcher, rounds: rounds);

      await engine.run(customerClosure());

      expect(rounds.single, isEmpty);
    },
  );

  test(
    'a timeout (TimeoutException) leaves the round set empty — retryable',
    () async {
      final rounds = <Set<String>>[];
      final fetcher = PullPageFetcher(
        listHttp: (doctype, params) async {
          throw TimeoutException('request timed out');
        },
      );
      final engine = buildEngine(fetcher: fetcher, rounds: rounds);

      await engine.run(customerClosure());

      expect(rounds.single, isEmpty);
    },
  );

  test(
    'a SocketException leaves the round set empty — retryable',
    () async {
      final rounds = <Set<String>>[];
      final fetcher = PullPageFetcher(
        listHttp: (doctype, params) async {
          throw const SocketException('Connection refused');
        },
      );
      final engine = buildEngine(fetcher: fetcher, rounds: rounds);

      await engine.run(customerClosure());

      expect(rounds.single, isEmpty);
    },
  );

  test(
    'a "no such table" DatabaseException leaves the round set empty — retryable',
    () async {
      final rounds = <Set<String>>[];
      final fetcher = PullPageFetcher(
        listHttp: (doctype, params) async {
          throw SqfliteDatabaseException(
            'no such table: docs__customer',
            null,
          );
        },
      );
      final engine = buildEngine(fetcher: fetcher, rounds: rounds);

      await engine.run(customerClosure());

      expect(rounds.single, isEmpty);
    },
  );

  test(
    'a plain non-FrappeException with no statusCode leaves the round set empty',
    () async {
      final rounds = <Set<String>>[];
      final fetcher = PullPageFetcher(
        listHttp: (doctype, params) async {
          throw Exception('boom');
        },
      );
      final engine = buildEngine(fetcher: fetcher, rounds: rounds);

      await engine.run(customerClosure());

      expect(rounds.single, isEmpty);
    },
  );

  test(
    'a full 200 drain fires onDoctypePullOk and reports an empty round set',
    () async {
      final rounds = <Set<String>>[];
      final okCalls = <String>[];
      final fetcher = PullPageFetcher(
        listHttp: (doctype, params) async => const <Map<String, dynamic>>[],
      );
      final engine = buildEngine(
        fetcher: fetcher,
        rounds: rounds,
        okCalls: okCalls,
      );

      await engine.run(customerClosure());

      expect(
        okCalls,
        ['Customer'],
        reason: 'a fully-drained (200) doctype self-heals via onDoctypePullOk',
      );
      expect(
        rounds.single,
        isEmpty,
        reason: 'no 403 this round → the denied-set is empty',
      );
    },
  );

  test(
    'onPermissionDeniedRound throwing does not crash the pull (caught + logged)',
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
        onPermissionDeniedRound: (denied) async {
          throw Exception('DB write failed');
        },
      );

      // Must complete without throwing/propagating the callback's error.
      await engine.run(customerClosure());
    },
  );

  test(
    'no onPermissionDeniedRound wired (null) — a 403 does not crash the pull',
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
