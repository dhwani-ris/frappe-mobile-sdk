import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/utils/attachment_pick.dart';
import 'package:frappe_mobile_sdk/src/utils/media_store.dart';

/// The reported bug: pick, then re-pick without saving, and both files stay on
/// disk. Exercised through the pick + discard helpers the widgets call, because
/// widget tests run in a fake-async zone where real dart:io never completes.
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('replace');
    MediaStore.overrideRootForTest(root.path);
  });

  tearDown(() async {
    MediaStore.overrideRootForTest(null);
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('replacing a staged value deletes the previous staged file', () async {
    final first = File('${root.path}/first.jpg')..writeAsStringSync('FIRST');
    final second = File('${root.path}/second.jpg')..writeAsStringSync('SECOND');

    final v1 = await resolvePickedAttachment(
      picked: first,
      online: false,
      offlineModeEnabled: true,
    );
    // What the field now does immediately before didChange.
    await MediaStore.discardReplacedValue(v1);
    final v2 = await resolvePickedAttachment(
      picked: second,
      online: false,
      offlineModeEnabled: true,
    );

    expect(
      File(v1!).existsSync(),
      isFalse,
      reason: 'the replaced file is gone',
    );
    expect(File(v2!).existsSync(), isTrue);

    // And exactly one staged file remains — the reported symptom.
    final staged = Directory(
      '${root.path}/mform_attachments/outbox',
    ).listSync(recursive: true).whereType<File>().length;
    expect(staged, 1);
  });

  test('a host path outside the store is NEVER deleted', () async {
    // A host may point a field at the gallery. Deleting that would destroy the
    // user's own photo.
    final hostFile = File('${root.path}/gallery.jpg')
      ..writeAsStringSync('MINE');
    await MediaStore.discardReplacedValue(hostFile.path);
    expect(hostFile.existsSync(), isTrue);
  });

  test('a pending marker is never treated as a path', () async {
    // The pending_attachments row owns that file; deleting it here would
    // strand the queue entry with no bytes.
    final staged = await MediaStore.stageToOutbox(
      File('${root.path}/queued.jpg')..writeAsStringSync('Q'),
      nameGen: () => 'uq',
    );
    await MediaStore.discardReplacedValue('pending:42');
    expect(File(staged).existsSync(), isTrue);
  });

  test('null, empty and a server url are no-ops', () async {
    await MediaStore.discardReplacedValue(null);
    await MediaStore.discardReplacedValue('');
    await MediaStore.discardReplacedValue('   ');
    await MediaStore.discardReplacedValue('/files/on-server.jpg');
    await MediaStore.discardReplacedValue('https://s3/a.jpg');
  });

  test('a cache path is not deleted — it is not staged data', () async {
    final staged = await MediaStore.stageToOutbox(
      File('${root.path}/c.jpg')..writeAsStringSync('C'),
      nameGen: () => 'uc',
    );
    await MediaStore.moveToCache(staged, '/files/c.jpg');
    final cached = await MediaStore.cachePathFor('/files/c.jpg');

    await MediaStore.discardReplacedValue(cached);

    expect(File(cached).existsSync(), isTrue);
  });
}
