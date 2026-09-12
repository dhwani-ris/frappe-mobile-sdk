import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/api/client.dart';
import 'package:frappe_mobile_sdk/src/database/daos/doctype_meta_dao.dart';
import 'package:frappe_mobile_sdk/src/database/schema/parent_schema.dart';
import 'package:frappe_mobile_sdk/src/database/schema/system_tables.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/offline_mode.dart';
import 'package:frappe_mobile_sdk/src/query/unified_resolver.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Captures the outgoing request so the test can assert what actually reached
/// Frappe, rather than what the resolver intended to send.
class _CapturingServer extends http.BaseClient {
  final List<Uri> seen = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    seen.add(request.url);
    return http.StreamedResponse(
      Stream.fromIterable([utf8.encode('{"data": []}')]),
      200,
      headers: const {'content-type': 'application/json'},
    );
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late DoctypeMetaDao metaDao;
  late _CapturingServer server;

  UnifiedResolver buildResolver() => UnifiedResolver(
    db: db,
    metaDao: metaDao,
    isOnline: () => true,
    backgroundFetch: (_, _) async {},
    metaResolver: (name) async => DocTypeMeta(
      name: name,
      fields: [DocField(fieldname: 'customer_name', fieldtype: 'Data')],
    ),
    // The configuration the app actually ships with. Every resolve() returns
    // through the online passthrough in this mode.
    offlineMode: const OfflineMode(enabled: false, isPersisted: true),
    client: FrappeClient('http://localhost', httpClient: server),
  );

  setUp(() async {
    server = _CapturingServer();
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
    final m = DocTypeMeta(
      name: 'Customer',
      fields: [DocField(fieldname: 'customer_name', fieldtype: 'Data')],
    );
    for (final s in buildParentSchemaDDL(m, tableName: 'docs__customer')) {
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

  group('online passthrough sanitizes local-only filter columns', () {
    // This is the EXACT shape LinkOptionService._resolveLinkTitle emits: a
    // Link value is the target's Frappe `name`, which locally is either
    // `server_name` (synced) or `mobile_uuid` (not yet pushed). Forwarded
    // verbatim, Frappe answers
    //   DataError - Field not permitted in query: server_name   (HTTP 417)
    // once per Link target per form open.
    test('rewrites server_name to name and drops mobile_uuid', () async {
      await buildResolver().resolve(
        doctype: 'Customer',
        orFilters: [
          ['server_name', '=', 'SA-1000'],
          ['mobile_uuid', '=', 'SA-1000'],
        ],
        pageSize: 1,
      );

      expect(server.seen, isNotEmpty, reason: 'no request was sent');
      final sent = Uri.decodeFull(server.seen.single.toString());
      expect(sent, contains('["name","=","SA-1000"]'));
      expect(sent, isNot(contains('server_name')));
      expect(sent, isNot(contains('mobile_uuid')));
    });

    test('sanitizes AND filters on the same path', () async {
      await buildResolver().resolve(
        doctype: 'Customer',
        filters: [
          ['server_name', '=', 'CUST-1'],
        ],
      );

      final sent = Uri.decodeFull(server.seen.single.toString());
      expect(sent, contains('["name","=","CUST-1"]'));
      expect(sent, isNot(contains('server_name')));
    });

    test('sends NOTHING when an OR list sanitizes away entirely', () async {
      // Every clause named mobile_uuid, i.e. the caller wanted a row that
      // has never been pushed. Sending `or_filters: []` would drop the
      // constraint and match every row — broader than asked.
      final res = await buildResolver().resolve(
        doctype: 'Customer',
        orFilters: [
          ['mobile_uuid', '=', 'u-local-only'],
        ],
      );

      expect(server.seen, isEmpty);
      expect(res.rows, isEmpty);
    });

    test('leaves ordinary business columns untouched', () async {
      await buildResolver().resolve(
        doctype: 'Customer',
        filters: [
          ['customer_name', 'like', '%acme%'],
        ],
      );

      final sent = Uri.decodeFull(server.seen.single.toString());
      expect(sent, contains('customer_name'));
      expect(sent, contains('%acme%'));
    });
  });
}
