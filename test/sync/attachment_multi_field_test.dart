// N parent attach fields + X child rows with M each.
//
// Everything is stamped with the TOP parent's mobile_uuid at enqueue, so one
// query finds all N + (X * M) attachments and the push gate blocks on them
// together. These tests pin the fan-out, the per-row writeback targets, and
// what happens when one attachment in the middle of the set fails.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/api/exceptions.dart';
import 'package:frappe_mobile_sdk/src/database/daos/media_cache_dao.dart';
import 'package:frappe_mobile_sdk/src/database/daos/pending_attachment_dao.dart';
import 'package:frappe_mobile_sdk/src/database/schema/child_schema.dart';
import 'package:frappe_mobile_sdk/src/database/schema/parent_schema.dart';
import 'package:frappe_mobile_sdk/src/database/schema/system_tables.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/outbox_row.dart';
import 'package:frappe_mobile_sdk/src/models/pending_attachment.dart';
import 'package:frappe_mobile_sdk/src/services/local_writer.dart';
import 'package:frappe_mobile_sdk/src/sync/attachment_pipeline.dart';
import 'package:frappe_mobile_sdk/src/sync/child_table_info.dart';
import 'package:frappe_mobile_sdk/src/sync/payload_assembler.dart';
import 'package:frappe_mobile_sdk/src/sync/push_error.dart';
import 'package:frappe_mobile_sdk/src/utils/media_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DocField f(String n, String t, {String? options}) =>
    DocField(fieldname: n, fieldtype: t, label: n, options: options);

/// N = 2 parent attach fields, M = 2 child attach fields.
const int kParentFields = 2;
const int kChildFields = 2;
const int kChildRows = 3;
const int kTotal = kParentFields + (kChildRows * kChildFields); // 8

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late LocalWriter writer;
  late PendingAttachmentDao dao;
  late Directory tmp;
  late Directory storeRoot;
  var uploadCalls = 0;
  final uploadedContents = <String>[];

  final parentMeta = DocTypeMeta(
    name: 'Order',
    titleField: 'title',
    fields: [
      f('title', 'Data'),
      f('photo', 'Attach'),
      f('scan', 'Attach Image'),
      f('items', 'Table', options: 'Order Item'),
    ],
  );
  final childMeta = DocTypeMeta(
    name: 'Order Item',
    isTable: true,
    fields: [
      f('label', 'Data'),
      f('receipt', 'Attach'),
      f('signature', 'Attach Image'),
    ],
  );

  Future<DocTypeMeta> metaFn(String dt) async {
    if (dt == 'Order') return parentMeta;
    if (dt == 'Order Item') return childMeta;
    throw StateError('unexpected meta lookup: $dt');
  }

  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    for (final s in systemTablesDDL()) {
      await db.execute(s);
    }
    for (final s in buildParentSchemaDDL(
      parentMeta,
      tableName: 'docs__order',
    )) {
      await db.execute(s);
    }
    for (final s in buildChildSchemaDDL(
      childMeta,
      tableName: 'docs__order_item',
    )) {
      await db.execute(s);
    }
    writer = LocalWriter(db, metaFn);
    dao = PendingAttachmentDao(db);
    tmp = await Directory.systemTemp.createTemp('multifield');
    storeRoot = await Directory.systemTemp.createTemp('multistore');
    MediaStore.overrideRootForTest(storeRoot.path);
    uploadCalls = 0;
    uploadedContents.clear();
  });

  tearDown(() async {
    MediaStore.overrideRootForTest(null);
    await db.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
    if (await storeRoot.exists()) await storeRoot.delete(recursive: true);
  });

  /// Distinct bytes per field so each upload yields a distinct url — a
  /// mis-mapped writeback then shows up as the wrong url in a slot rather than
  /// passing by coincidence.
  Future<String> stage(String tag) async {
    final src = File('${tmp.path}/$tag.jpg')..writeAsStringSync(tag);
    return MediaStore.stageToOutbox(src, nameGen: () => 'uid_$tag');
  }

  Future<void> saveDocument() async {
    final items = <Map<String, dynamic>>[];
    for (var r = 0; r < kChildRows; r++) {
      items.add({
        'mobile_uuid': 'C$r',
        'label': 'row$r',
        'receipt': await stage('receipt$r'),
        'signature': await stage('signature$r'),
      });
    }
    await writer.writeParent(
      parentDoctype: 'Order',
      data: {
        'mobile_uuid': 'P1',
        'title': 'multi',
        'photo': await stage('photo'),
        'scan': await stage('scan'),
        'items': items,
      },
    );
  }

  AttachmentPipeline pipeline({String? failOnContent, Object? error}) =>
      AttachmentPipeline(
        dao: dao,
        db: db,
        backoff: const [Duration.zero, Duration.zero, Duration.zero],
        tableNameFor: (dt) async =>
            dt == 'Order' ? 'docs__order' : 'docs__order_item',
        uploader: (file, {doctype, docname, fileName, isPrivate = true}) async {
          uploadCalls++;
          final content = await file.readAsString();
          if (failOnContent != null && content == failOnContent) {
            throw error ?? NetworkException('down');
          }
          uploadedContents.add(content);
          return {'file_url': '/files/$content.jpg', 'name': '$content.jpg'};
        },
      );

  final outboxRow = OutboxRow(
    id: 1,
    doctype: 'Order',
    mobileUuid: 'P1',
    operation: OutboxOperation.insert,
    state: OutboxState.pending,
    retryCount: 0,
    createdAt: DateTime.utc(2026, 1, 1),
  );

  Future<Map<String, Object?>> assemble() => PayloadAssembler.assemble(
    db: db,
    row: outboxRow,
    parentMeta: parentMeta,
    parentTable: 'docs__order',
    childMetasByFieldname: {'items': ChildTableInfo('Order Item', childMeta)},
    resolveServerName: (_, _) async => null,
  );

  test('all N + (X*M) attachments are found by ONE top-parent query', () async {
    await saveDocument();
    final rows = await dao.findUnresolvedForTopParent('P1');
    expect(rows.length, kTotal);
    // Parent fields carry the parent's own uuid; child fields carry the child
    // row's uuid — but every row shares the TOP parent's uuid.
    expect(rows.every((r) => r.topParentUuid == 'P1'), isTrue);
    expect(
      rows.where((r) => r.parentUuid == 'P1').length,
      kParentFields,
      reason: 'parent-field rows',
    );
    for (var r = 0; r < kChildRows; r++) {
      expect(
        rows.where((x) => x.parentUuid == 'C$r').length,
        kChildFields,
        reason: 'child row C$r',
      );
    }
  });

  test(
    'every field is uploaded exactly once and written back to its own slot',
    () async {
      await saveDocument();
      final resolved = await pipeline().resolveForTopParent('P1');

      expect(resolved.length, kTotal);
      expect(
        uploadCalls,
        kTotal,
        reason: 'one upload per field, no duplicates',
      );

      // Parent columns.
      final parent = (await db.query('docs__order')).single;
      expect(parent['photo'], '/files/photo.jpg');
      expect(parent['scan'], '/files/scan.jpg');

      // Each child row's own columns — the writeback targets docs__order_item
      // keyed by the CHILD's mobile_uuid, so a mis-keyed update would cross-wire
      // rows and show up here.
      for (var r = 0; r < kChildRows; r++) {
        final child = (await db.query(
          'docs__order_item',
          where: 'mobile_uuid = ?',
          whereArgs: ['C$r'],
        )).single;
        expect(child['receipt'], '/files/receipt$r.jpg');
        expect(child['signature'], '/files/signature$r.jpg');
      }
    },
  );

  test(
    'the assembled payload carries no marker anywhere, parent or child',
    () async {
      await saveDocument();
      final p = pipeline();
      await p.resolveForTopParent('P1');

      final payload = AttachmentPipeline.inlinePayload(
        await assemble(),
        resolved: await p.resolutionMapFor('P1'),
      );

      expect(payload['photo'], '/files/photo.jpg');
      final items = (payload['items'] as List).cast<Map>();
      expect(items.length, kChildRows);
      for (var r = 0; r < kChildRows; r++) {
        final row = items.firstWhere((m) => m['label'] == 'row$r');
        expect(row['receipt'], '/files/receipt$r.jpg');
        expect(row['signature'], '/files/signature$r.jpg');
      }
      expect(payload.toString().contains('pending:'), isFalse);
    },
  );

  test('each distinct file becomes its own cache entry', () async {
    await saveDocument();
    await pipeline().resolveForTopParent('P1');
    expect((await db.query('media_cache')).length, kTotal);
    final cache = MediaCacheDao(db);
    for (final tag in ['photo', 'scan', 'receipt0', 'signature2']) {
      final e = await cache.findByUrl('/files/$tag.jpg');
      expect(e, isNotNull, reason: tag);
      expect(File(e!.localPath).readAsStringSync(), tag);
    }
  });

  test('ONE failure blocks the whole document and stops the pass', () async {
    await saveDocument();
    // receipt1 is the 4th row by enqueue order (photo, scan, receipt0,
    // signature0, receipt1, ...). Uploads are serial, so everything after it
    // is never attempted in this dispatch.
    await expectLater(
      pipeline(failOnContent: 'receipt1').resolveForTopParent('P1'),
      throwsA(isA<BlockedByUpstream>()),
    );

    final rows = await dao.findAllForTopParent('P1');
    final done = rows.where((r) => r.state == AttachmentState.done);
    final failed = rows.where((r) => r.state == AttachmentState.failed);
    final untouched = rows.where((r) => r.state == AttachmentState.pending);

    expect(failed.length, 1);
    expect(failed.single.parentFieldname, 'receipt');
    expect(
      done.isNotEmpty,
      isTrue,
      reason: 'earlier uploads are committed — progress is not thrown away',
    );
    expect(
      untouched.isNotEmpty,
      isTrue,
      reason: 'a serial loop never reaches the rest after the first throw',
    );
    expect(done.length + failed.length + untouched.length, kTotal);
  });

  test(
    'the next dispatch finishes the set without re-uploading what landed',
    () async {
      await saveDocument();
      await expectLater(
        pipeline(failOnContent: 'receipt1').resolveForTopParent('P1'),
        throwsA(isA<BlockedByUpstream>()),
      );
      final callsAfterFailure = uploadCalls;
      final doneAfterFailure = (await dao.findAllForTopParent(
        'P1',
      )).where((r) => r.state == AttachmentState.done).length;

      // Retry with a working uploader.
      await pipeline().resolveForTopParent('P1');

      expect(
        (await dao.findAllForTopParent(
          'P1',
        )).every((r) => r.state == AttachmentState.done),
        isTrue,
      );
      // Total uploads = the failed attempts + one per attachment that had not
      // yet succeeded. Nothing already `done` is uploaded a second time.
      expect(uploadCalls, callsAfterFailure + (kTotal - doneAfterFailure));

      final parent = (await db.query('docs__order')).single;
      expect(parent['photo'], '/files/photo.jpg');
      for (var r = 0; r < kChildRows; r++) {
        final child = (await db.query(
          'docs__order_item',
          where: 'mobile_uuid = ?',
          whereArgs: ['C$r'],
        )).single;
        expect(child['receipt'], '/files/receipt$r.jpg');
      }
    },
  );

  test(
    'one TERMINAL rejection out of the set blocks every later dispatch',
    () async {
      await saveDocument();
      await expectLater(
        pipeline(
          failOnContent: 'signature0',
          error: ValidationException('File size exceeded', {
            'exc_type': 'MaxFileSizeReachedError',
          }),
        ).resolveForTopParent('P1'),
        throwsA(isA<BlockedByUpstream>()),
      );
      expect(
        (await dao.findAllForTopParent('P1'))
            .where((r) => r.state == AttachmentState.rejected)
            .single
            .parentFieldname,
        'signature',
      );

      // Even a fully working uploader cannot clear it — only replacing the file
      // can, and until then the document must never push.
      await expectLater(
        pipeline().resolveForTopParent('P1'),
        throwsA(isA<BlockedByUpstream>()),
      );
    },
  );
}
