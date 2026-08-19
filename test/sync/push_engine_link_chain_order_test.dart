import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/concurrency/concurrency_pool.dart';
import 'package:frappe_mobile_sdk/src/database/daos/doctype_meta_dao.dart';
import 'package:frappe_mobile_sdk/src/database/daos/outbox_dao.dart';
import 'package:frappe_mobile_sdk/src/database/daos/pending_attachment_dao.dart';
import 'package:frappe_mobile_sdk/src/database/schema/parent_schema.dart';
import 'package:frappe_mobile_sdk/src/database/schema/system_tables.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/outbox_row.dart';
import 'package:frappe_mobile_sdk/src/sync/idempotency_strategy.dart';
import 'package:frappe_mobile_sdk/src/sync/push_engine.dart';
import 'package:frappe_mobile_sdk/src/sync/sync_state_notifier.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Self-referencing Link chains where every record points at an EARLIER
/// record of the same doctype — the field-capture shape: A captured at
/// 13:00, B at 14:00 referencing A, C at 14:20 referencing B.
///
/// Because references always point backwards in time, capture order and
/// dependency order agree, and the whole chain must reach the server in
/// capture order. Any other order makes `UuidRewriter` fail to resolve the
/// parent's `server_name` and the row lands `blocked` — the "link reference
/// error" symptom.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late OutboxDao outbox;
  late DoctypeMetaDao metaDao;

  // Realistic mobile_uuids: `looksLikeMobileUuid` matches the canonical
  // 8-4-4-4-12 hex shape, and the dep scan relies on it whenever the
  // `__is_local` companion flag was never written.
  String uuidFor(int n) {
    final h = n.toRadixString(16).padLeft(4, '0');
    // Canonical 8-4-4-4-12, version 4, variant 8.
    return '0000$h-0000-4000-8000-00000000$h';
  }

  DocTypeMeta meta() => DocTypeMeta(
    name: 'Visit',
    autoname: 'field:mobile_uuid',
    fields: [
      DocField(fieldname: 'title', fieldtype: 'Data', label: 'Title'),
      DocField(
        fieldname: 'previous_visit',
        fieldtype: 'Link',
        label: 'Previous Visit',
        options: 'Visit',
      ),
    ],
  );

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
    for (final s in buildParentSchemaDDL(meta(), tableName: 'docs__visit')) {
      await db.execute(s);
    }
    await db.insert('doctype_meta', {
      'doctype': 'Visit',
      'metaJson': '{}',
      'isMobileForm': 0,
      'table_name': 'docs__visit',
    });
    outbox = OutboxDao(db);
    metaDao = DoctypeMetaDao(db);
  });

  tearDown(() async => db.close());

  /// Builds a chain of [depth] records: record 0 has no reference, record i
  /// references record i-1. Queued in capture order, one minute apart.
  /// [flagLocal] mirrors the picker path that writes `<field>__is_local=1`;
  /// when false the value is a bare UUID and only the shape check can see it.
  Future<List<String>> seedChain(int depth, {required bool flagLocal}) async {
    final uuids = [for (var i = 0; i < depth; i++) uuidFor(i + 1)];
    final capture = DateTime.utc(2026, 1, 1, 13);
    for (var i = 0; i < depth; i++) {
      await db.insert('docs__visit', {
        'mobile_uuid': uuids[i],
        'sync_status': 'dirty',
        'local_modified': 1,
        'title': 'visit-$i',
        'previous_visit': i == 0 ? null : uuids[i - 1],
        'previous_visit__is_local': i == 0 || !flagLocal ? null : 1,
      });
      await outbox.insertPending(
        doctype: 'Visit',
        mobileUuid: uuids[i],
        operation: OutboxOperation.insert,
        createdAt: capture.add(Duration(minutes: i)),
      );
    }
    return uuids;
  }

  PushEngine buildEngine({
    required PushHttpSendFn send,
    int maxConcurrent = 4,
  }) => PushEngine(
    db: db,
    outboxDao: outbox,
    attachmentDao: PendingAttachmentDao(db),
    metaDao: metaDao,
    pool: ConcurrencyPool(maxConcurrent: maxConcurrent),
    notifier: SyncStateNotifier(),
    idempotencyStrategy: IdempotencyStrategy(serverHasDedupHook: false),
    metaResolver: (_) async => meta(),
    childMetaResolver: (dt) async =>
        DocTypeMeta(name: dt, isTable: true, fields: const []),
    send: send,
    serverFetcher: (_, _) async => throw StateError('not expected'),
    resolveServerName: (doctype, uuid) async {
      final r = await db.query(
        'docs__visit',
        columns: ['server_name'],
        where: 'mobile_uuid = ?',
        whereArgs: [uuid],
        limit: 1,
      );
      return r.isEmpty ? null : r.first['server_name'] as String?;
    },
    attachmentUploader:
        (file, {doctype, docname, fileName, isPrivate = true}) =>
            throw UnimplementedError(),
    attachmentBackoff: const [Duration.zero, Duration.zero, Duration.zero],
    networkBackoff: const [Duration.zero, Duration.zero, Duration.zero],
  );

  /// Drains once, returning the uuids in dispatch order plus what each row
  /// actually sent in its `previous_visit` field.
  Future<(List<String>, Map<String, Object?>)> drain() async {
    final order = <String>[];
    final linkSent = <String, Object?>{};
    final engine = buildEngine(
      send: (method, payload, serverName) async {
        final uuid = payload['mobile_uuid'] as String;
        order.add(uuid);
        linkSent[uuid] = payload['previous_visit'];
        await Future<void>.delayed(Duration.zero);
        return {'name': 'SRV-$uuid', 'modified': '2026-01-01 00:00:00'};
      },
    );
    await engine.runOnce();
    return (order, linkSent);
  }

  test('3-deep chain with __is_local set syncs in capture order', () async {
    final uuids = await seedChain(3, flagLocal: true);
    final (order, linkSent) = await drain();

    expect(order, uuids);
    expect(linkSent[uuids[0]], isNull);
    expect(linkSent[uuids[1]], 'SRV-${uuids[0]}');
    expect(linkSent[uuids[2]], 'SRV-${uuids[1]}');
    expect(await db.query('outbox'), isEmpty);
  });

  test('3-deep chain WITHOUT __is_local (bare UUID, shape check only) '
      'syncs in capture order', () async {
    final uuids = await seedChain(3, flagLocal: false);
    final (order, linkSent) = await drain();

    expect(order, uuids);
    expect(linkSent[uuids[1]], 'SRV-${uuids[0]}');
    expect(linkSent[uuids[2]], 'SRV-${uuids[1]}');
  });

  test('8-deep chain syncs in capture order with no blocked rows', () async {
    final uuids = await seedChain(8, flagLocal: true);
    final (order, linkSent) = await drain();

    expect(order, uuids);
    for (var i = 1; i < uuids.length; i++) {
      expect(
        linkSent[uuids[i]],
        'SRV-${uuids[i - 1]}',
        reason: 'record $i must send its parent\'s server_name, not a uuid',
      );
    }
    expect(
      await db.query('outbox'),
      isEmpty,
      reason: 'no row may end blocked — that is the link-reference error',
    );
  });

  test('a chain whose head already synced still orders the tail', () async {
    final uuids = await seedChain(3, flagLocal: true);
    // Head already pushed in an earlier drain: it has a server_name and no
    // outbox row, so it is NOT in the pending set the tiering sees.
    await db.update(
      'docs__visit',
      {'server_name': 'SRV-${uuids[0]}', 'sync_status': 'synced'},
      where: 'mobile_uuid = ?',
      whereArgs: [uuids[0]],
    );
    await db.delete('outbox', where: 'mobile_uuid = ?', whereArgs: [uuids[0]]);

    final (order, linkSent) = await drain();

    expect(order, [uuids[1], uuids[2]]);
    expect(linkSent[uuids[1]], 'SRV-${uuids[0]}');
    expect(linkSent[uuids[2]], 'SRV-${uuids[1]}');
  });
}
