import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/api/client.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/outbox_row.dart';
import 'package:frappe_mobile_sdk/src/services/sync_engine_builder.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakeServer extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.method == 'POST' &&
        request.url.path.contains('/api/resource/Customer')) {
      const body =
          '{"data": {"name": "CUST-001", "modified": "2026-05-07 10:00:00"}}';
      return http.StreamedResponse(
        Stream.fromIterable([body.codeUnits]),
        200,
        headers: const {'content-type': 'application/json'},
      );
    }
    return http.StreamedResponse(
      Stream.fromIterable(['{}'.codeUnits]),
      200,
      headers: const {'content-type': 'application/json'},
    );
  }
}

DocTypeMeta _customerMeta() => DocTypeMeta(
  name: 'Customer',
  isTable: false,
  fields: [DocField(fieldname: 'customer_name', fieldtype: 'Data')],
);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase appDb;

  setUp(() async {
    appDb = await AppDatabase.inMemoryDatabase();
  });

  tearDown(() async => appDb.close());

  test(
    'outbox INSERT row drains: HTTP POST → docs__ updated → outbox empty',
    () async {
      final client = FrappeClient(
        'http://localhost',
        httpClient: _FakeServer(),
      );
      final pack = await SyncEngineBuilder.build(
        database: appDb,
        client: client,
        metaResolver: (_) async => _customerMeta(),
        runPullFn: () async => const <String>{},
        applyServerDoc: (_, _) async {},
        runPullForDoctypes: (_) async {},
        concurrencyOverride: 2,
      );

      final raw = appDb.rawDatabase;
      await raw.execute('''
        CREATE TABLE docs__customer (
          mobile_uuid TEXT PRIMARY KEY,
          server_name TEXT,
          sync_status TEXT NOT NULL DEFAULT 'dirty',
          sync_error TEXT,
          error_code TEXT,
          sync_attempts INTEGER NOT NULL DEFAULT 0,
          last_attempt_at INTEGER,
          sync_op TEXT,
          push_base_payload TEXT,
          docstatus INTEGER NOT NULL DEFAULT 0,
          modified TEXT,
          local_modified INTEGER NOT NULL,
          pulled_at INTEGER,
          customer_name TEXT
        )
      ''');
      await raw.insert('docs__customer', {
        'mobile_uuid': 'u1',
        'sync_status': 'dirty',
        'sync_op': 'INSERT',
        'local_modified': 1,
        'customer_name': 'Acme',
      });
      await raw.insert('outbox', {
        'doctype': 'Customer',
        'mobile_uuid': 'u1',
        'operation': OutboxOperation.insert.wireName,
        'state': OutboxState.pending.wireName,
        'created_at': 100,
      });

      await pack.pushEngine.runOnce();

      // Outbox row was deleted on success (markDone deletes the row).
      final outbox = await raw.query('outbox');
      expect(outbox, isEmpty);

      // docs__ row was updated with server_name. The sync_status flip to
      // 'synced' depends on retirement Phase 7's writeback finalization
      // rule, which lands separately. For now, server_name is the
      // strongest cross-phase assertion.
      final docs = await raw.query('docs__customer');
      expect(docs.length, 1);
      expect(docs.first['server_name'], 'CUST-001');
    },
  );
}
