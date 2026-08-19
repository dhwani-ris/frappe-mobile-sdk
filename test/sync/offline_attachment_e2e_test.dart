import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/daos/pending_attachment_dao.dart';
import 'package:frappe_mobile_sdk/src/database/schema/system_tables.dart';
import 'package:frappe_mobile_sdk/src/sync/attachment_pipeline.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Producer -> consumer contract for the offline attachment pipeline.
///
/// Task 4 proves the save side writes one `pending:<id>` marker per attach
/// field (parent + each child row) and one pending_attachments row with the
/// right coordinates. This test proves the consumer half resolves EVERY marker
/// into its own field slot for the worst case: N=2 parent fields + M=2 child
/// rows x K=1 child field = 4 markers, with children nested in a list.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late PendingAttachmentDao dao;
  late Directory tmp;

  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    for (final s in systemTablesDDL()) {
      await db.execute(s);
    }
    dao = PendingAttachmentDao(db);
    tmp = await Directory.systemTemp.createTemp('e2e');
  });

  tearDown(() async {
    await db.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<int> enqueueLocal({
    required String parentUuid,
    required String parentDoctype,
    required String field,
    required String content,
  }) async {
    final f = File('${tmp.path}/${parentUuid}_$field.bin')
      ..writeAsStringSync(content);
    return dao.enqueue(
      parentDoctype: parentDoctype,
      parentUuid: parentUuid,
      parentFieldname: field,
      topParentUuid: 'P1',
      topParentDoctype: 'Order',
      localPath: f.path,
      fileName: '$field.bin',
    );
  }

  test(
    '4 markers (2 parent + 2 child) each resolve to their own file_url',
    () async {
      // N=2 parent attach fields
      final idPhoto = await enqueueLocal(
        parentUuid: 'P1',
        parentDoctype: 'Order',
        field: 'photo',
        content: 'A',
      );
      final idScan = await enqueueLocal(
        parentUuid: 'P1',
        parentDoctype: 'Order',
        field: 'scan',
        content: 'B',
      );
      // M=2 child rows, K=1 attach field each
      final idR0 = await enqueueLocal(
        parentUuid: 'C0',
        parentDoctype: 'Order Item',
        field: 'receipt',
        content: 'C',
      );
      final idR1 = await enqueueLocal(
        parentUuid: 'C1',
        parentDoctype: 'Order Item',
        field: 'receipt',
        content: 'D',
      );

      // Payload shaped exactly as PayloadAssembler produces it from docs__:
      // parent user fields + a child list of maps, each holding its marker.
      final payload = <String, Object?>{
        'doctype': 'Order',
        'photo': 'pending:$idPhoto',
        'scan': 'pending:$idScan',
        'title': 'plain field untouched',
        'items': [
          {'idx': 0, 'receipt': 'pending:$idR0', 'label': 'row0'},
          {'idx': 1, 'receipt': 'pending:$idR1', 'label': 'row1'},
        ],
      };

      // Real pipeline; uploader returns a unique url per file so mis-mapping
      // would surface as a wrong url in a slot.
      final uploaded = <String, String>{};
      final pipeline = AttachmentPipeline(
        dao: dao,
        db: db,
        uploader: (file, {doctype, docname, fileName, isPrivate = true}) async {
          final content = await file.readAsString();
          final url = '/files/${fileName}_$content';
          uploaded[content] = url;
          return {'file_url': url, 'name': fileName};
        },
      );

      final resolved = await pipeline.resolveForTopParent('P1');
      expect(resolved.length, 4);

      final out = AttachmentPipeline.inlinePayload(payload, resolved: resolved);

      // Each marker resolved to ITS OWN file_url in ITS OWN slot.
      expect(out['photo'], '/files/photo.bin_A');
      expect(out['scan'], '/files/scan.bin_B');
      expect(out['title'], 'plain field untouched');
      final items = (out['items'] as List).cast<Map>();
      expect(items[0]['receipt'], '/files/receipt.bin_C');
      expect(items[1]['receipt'], '/files/receipt.bin_D');

      // No marker left behind anywhere.
      expect(out.toString().contains('pending:'), isFalse);

      // Durable copies reclaimed after upload.
      expect(Directory(tmp.path).listSync().isEmpty, isTrue);
    },
  );
}
