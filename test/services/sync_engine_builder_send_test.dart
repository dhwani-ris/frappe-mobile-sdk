import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/api/client.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/outbox_row.dart';
import 'package:frappe_mobile_sdk/src/services/sync_engine_builder.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _RecordingClient extends http.BaseClient {
  final List<({String method, String url, String body})> calls = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = request is http.Request ? request.body : '';
    calls.add((
      method: request.method,
      url: request.url.toString(),
      body: body,
    ));
    final responseBody =
        '{"data": {"name": "CUST-001", "modified": "2026-05-07 10:00:00"}}';
    return http.StreamedResponse(
      Stream.fromIterable([responseBody.codeUnits]),
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

  test('PushEngine drives the send callback to POST /api/resource/{doctype} '
      'on INSERT', () async {
    final recorder = _RecordingClient();
    final client = FrappeClient('http://localhost', httpClient: recorder);
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

    // Assert that an HTTP POST landed on /api/resource/Customer with the
    // user field in the body.
    final post = recorder.calls.firstWhere(
      (c) => c.method == 'POST' && c.url.contains('/api/resource/Customer'),
      orElse: () => (method: '', url: '', body: ''),
    );
    expect(post.method, 'POST', reason: 'recorded calls: ${recorder.calls}');
    expect(post.url, contains('/api/resource/Customer'));
    expect(post.body, contains('"customer_name":"Acme"'));
  });
}
