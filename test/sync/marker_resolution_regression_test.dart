// Regression suite for the three marker-corruption paths (F1 / F1b / F1c).
//
// These began as repros that ASSERTED the bug: that a `pending:<id>` marker
// survived a second dispatch and reached Frappe verbatim, and that retrying a
// blocked row silently "succeeded" with the marker in the payload. Same setup,
// opposite assertions — that inversion is the proof the fix holds.
//
// Every stage is the real production path, with NO hand-built payload:
//   LocalWriter.writeParent   -> writes the marker into docs__
//   AttachmentPipeline        -> uploads, writes back, marks done
//   PayloadAssembler.assemble -> rebuilds the payload from docs__
//   inlinePayload             -> must never see an unresolved marker
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/api/exceptions.dart';
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

  final parentMeta = DocTypeMeta(
    name: 'Order',
    titleField: 'title',
    fields: [
      f('title', 'Data'),
      f('photo', 'Attach'),
      f('items', 'Table', options: 'Order Item'),
    ],
  );
  final childMeta = DocTypeMeta(
    name: 'Order Item',
    isTable: true,
    fields: [f('label', 'Data'), f('receipt', 'Attach Image')],
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
    tmp = await Directory.systemTemp.createTemp('markerregr');
    storeRoot = await Directory.systemTemp.createTemp('markerstore');
    MediaStore.overrideRootForTest(storeRoot.path);
    uploadCalls = 0;
  });

  tearDown(() async {
    MediaStore.overrideRootForTest(null);
    await db.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
    if (await storeRoot.exists()) await storeRoot.delete(recursive: true);
  });

  final outboxRow = OutboxRow(
    id: 1,
    doctype: 'Order',
    mobileUuid: 'p-uuid-1',
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

  AttachmentPipeline pipeline({
    Future<Map<String, dynamic>> Function(File file)? onUpload,
  }) => AttachmentPipeline(
    dao: dao,
    db: db,
    backoff: const [Duration.zero, Duration.zero, Duration.zero],
    tableNameFor: (dt) async =>
        dt == 'Order' ? 'docs__order' : 'docs__order_item',
    uploader: (file, {doctype, docname, fileName, isPrivate = true}) async {
      uploadCalls++;
      if (onUpload != null) return onUpload(file);
      final url = '/files/${await file.readAsString()}.jpg';
      return {'file_url': url, 'name': fileName};
    },
  );

  Future<void> saveWithAttachments({bool withChild = true}) async {
    final photo = File('${tmp.path}/IMG_1.jpg')..writeAsStringSync('A');
    final receipt = File('${tmp.path}/receipt0.jpg')..writeAsStringSync('B');
    await writer.writeParent(
      parentDoctype: 'Order',
      data: {
        'mobile_uuid': 'p-uuid-1',
        'title': 'offline order',
        'photo': photo.path,
        'items': withChild
            ? [
                {'mobile_uuid': 'C1', 'label': 'row0', 'receipt': receipt.path},
              ]
            : const [],
      },
    );
  }

  test(
    'F1: a retry after a failed parent push resolves, and never re-uploads',
    () async {
      await saveWithAttachments();
      final p = pipeline();

      // Dispatch 1 — uploads succeed and the writeback replaces both markers.
      final r1 = await p.resolveForTopParent('p-uuid-1');
      expect(r1.length, 2, reason: 'parent photo + child receipt');
      expect(uploadCalls, 2);

      final p1 = AttachmentPipeline.inlinePayload(
        await assemble(),
        resolved: r1,
      );
      expect(p1['photo'], '/files/A.jpg');
      expect(((p1['items'] as List).first as Map)['receipt'], '/files/B.jpg');

      // ...the parent POST then fails (NetworkError) and the user taps retry.

      // Dispatch 2 — nothing outstanding, because the writeback already landed.
      final r2 = await p.resolveForTopParent('p-uuid-1');
      expect(r2, isEmpty, reason: 'every attachment is already done');
      expect(uploadCalls, 2, reason: 'F1: a retry must never re-upload');

      final p2 = AttachmentPipeline.inlinePayload(
        await assemble(),
        resolved: await p.resolutionMapFor('p-uuid-1'),
      );
      expect(
        p2['photo'],
        '/files/A.jpg',
        reason: 'F1 regression: a marker must never reach the wire',
      );
      expect(((p2['items'] as List).first as Map)['receipt'], '/files/B.jpg');
      expect(p2.toString().contains('pending:'), isFalse);
    },
  );

  test(
    'F1b: a terminally rejected attachment keeps blocking and never retries',
    () async {
      await saveWithAttachments(withChild: false);

      // Dispatch 1 — the upload is refused outright (an oversized file).
      await expectLater(
        pipeline(
          onUpload: (_) async => throw ValidationException(
            'File size exceeded the maximum',
            {'exc_type': 'MaxFileSizeReachedError'},
          ),
        ).resolveForTopParent('p-uuid-1'),
        throwsA(isA<BlockedByUpstream>()),
      );
      expect(
        (await dao.findAllForTopParent('p-uuid-1')).single.state,
        AttachmentState.rejected,
      );
      final callsBefore = uploadCalls;

      // The outbox row is `blocked`. SyncController.retryAll includes blocked
      // rows, so the user's retry re-dispatches it. Previously this SUCCEEDED
      // and wrote the literal string "pending:<id>" into Frappe.
      await expectLater(
        pipeline().resolveForTopParent('p-uuid-1'),
        throwsA(isA<BlockedByUpstream>()),
        reason: 'F1b regression: a rejected attachment always blocks the push',
      );
      expect(
        uploadCalls,
        callsBefore,
        reason: 'F1b: terminal rejection is never auto-retried',
      );

      // The marker is still in docs__ — which is fine, precisely BECAUSE the
      // push is blocked and can never carry it to the server.
      final photoColumn = (await db.query('docs__order')).single['photo'];
      expect(photoColumn, startsWith('pending:'));
    },
  );

  test('F1b: the blocked reason names the file so the user can act', () async {
    await saveWithAttachments(withChild: false);
    try {
      await pipeline(
        onUpload: (_) async => throw ValidationException('too big', {
          'exc_type': 'MaxFileSizeReachedError',
        }),
      ).resolveForTopParent('p-uuid-1');
      fail('expected BlockedByUpstream');
    } on BlockedByUpstream catch (e) {
      expect(e.message, contains('photo'));
      expect(e.message, contains('too big'));
    }
  });

  test(
    'F1c: a second dispatch in the same drain resolves from docs__',
    () async {
      // _autoMergeAndRetry recurses into _process, producing a second
      // _dispatchOnce with no user action. By then the attachments are done, so
      // this is the same seam as F1 — assert it holds without a fresh pipeline.
      await saveWithAttachments(withChild: false);
      final p = pipeline();
      await p.resolveForTopParent('p-uuid-1');

      final payload = AttachmentPipeline.inlinePayload(
        await assemble(),
        resolved: await p.resolutionMapFor('p-uuid-1'),
      );
      expect(payload['photo'], '/files/A.jpg');
      expect(uploadCalls, 1);
    },
  );

  test('an unresolved marker can never reach the payload silently', () {
    // Belt and braces: even if the push gate were bypassed, inlinePayload
    // refuses rather than shipping the marker as if it were a real value.
    expect(
      () => AttachmentPipeline.inlinePayload({
        'photo': 'pending:99',
      }, resolved: const {}),
      throwsA(isA<StateError>()),
    );
  });
}
