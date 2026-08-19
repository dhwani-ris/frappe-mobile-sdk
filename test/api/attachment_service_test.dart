import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:frappe_mobile_sdk/src/api/attachment_service.dart';
import 'package:frappe_mobile_sdk/src/api/rest_helper.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _MemoryPathProvider extends PathProviderPlatform {
  _MemoryPathProvider(this.tempDir);
  final Directory tempDir;
  @override
  Future<String?> getTemporaryPath() async => tempDir.path;
}

Future<File> _tempFile(String contents, String name) async {
  final dir = await Directory.systemTemp.createTemp('attach-test-');
  final f = File('${dir.path}/$name');
  await f.writeAsString(contents);
  return f;
}

void main() {
  setUpAll(() async {
    final dir = await Directory.systemTemp.createTemp('attach-pp-');
    PathProviderPlatform.instance = _MemoryPathProvider(dir);
  });

  AttachmentService makeSvc(http.Client client) =>
      AttachmentService(RestHelper('http://x', client: client));

  test(
    'uploadFile sends multipart with default is_private=1 and folder=Home',
    () async {
      final captured = <String, String>{};
      String? body;
      final client = MockClient.streaming((req, stream) async {
        // Capture the form fields by decoding the multipart body.
        final bytes = await stream.toBytes();
        body = utf8.decode(bytes, allowMalformed: true);
        // Pull "name="<k>"\r\n\r\n<v>\r\n" out of the multipart body.
        final fieldRe = RegExp(r'name="([^"]+)"\r\n\r\n([^\r]*)\r\n');
        for (final m in fieldRe.allMatches(body!)) {
          captured[m.group(1)!] = m.group(2)!;
        }
        return http.StreamedResponse(
          Stream.value(
            utf8.encode(
              jsonEncode({
                'message': {'file_url': '/files/x.txt', 'name': 'FILE-1'},
              }),
            ),
          ),
          200,
        );
      });

      final f = await _tempFile('hello', 'note.txt');
      final svc = makeSvc(client);
      final out = await svc.uploadFile(f, fileName: 'note.txt');
      expect(out['file_url'], '/files/x.txt');
      expect(captured['is_private'], '1');
      expect(captured['folder'], 'Home');
      // Frappe's upload_file reads form_dict.file_name — verified against
      // 16.25.0, 16.26.3 and 17.0.0-dev. The old `filename` key was ignored.
      expect(captured['file_name'], 'note.txt');
      expect(captured.containsKey('filename'), isFalse);
      expect(captured.containsKey('doctype'), isFalse);
      expect(captured.containsKey('docname'), isFalse);
    },
  );

  test(
    'uploadFile sends doctype + docname (the keys Frappe actually reads)',
    () async {
      final captured = <String, String>{};
      final client = MockClient.streaming((req, stream) async {
        final bytes = await stream.toBytes();
        final body = utf8.decode(bytes, allowMalformed: true);
        final fieldRe = RegExp(r'name="([^"]+)"\r\n\r\n([^\r]*)\r\n');
        for (final m in fieldRe.allMatches(body)) {
          captured[m.group(1)!] = m.group(2)!;
        }
        return http.StreamedResponse(
          Stream.value(
            utf8.encode(
              jsonEncode({
                'message': {'file_url': '/x'},
              }),
            ),
          ),
          200,
        );
      });
      final f = await _tempFile('hi', 'doc.txt');
      final svc = makeSvc(client);
      await svc.uploadFile(f, doctype: 'Customer', docname: 'CUST-1');
      // `dt`/`dn` are silently ignored by Frappe, which would produce an
      // unattached File — the trap this branch used to set for its next caller.
      expect(captured['doctype'], 'Customer');
      expect(captured['docname'], 'CUST-1');
      expect(captured.containsKey('dt'), isFalse);
      expect(captured.containsKey('dn'), isFalse);
    },
  );

  test('uploadFile honors isPrivate=false', () async {
    final captured = <String, String>{};
    final client = MockClient.streaming((req, stream) async {
      final bytes = await stream.toBytes();
      final body = utf8.decode(bytes, allowMalformed: true);
      final fieldRe = RegExp(r'name="([^"]+)"\r\n\r\n([^\r]*)\r\n');
      for (final m in fieldRe.allMatches(body)) {
        captured[m.group(1)!] = m.group(2)!;
      }
      return http.StreamedResponse(
        Stream.value(
          utf8.encode(
            jsonEncode({
              'message': {'file_url': '/x'},
            }),
          ),
        ),
        200,
      );
    });
    final f = await _tempFile('hi', 'pub.txt');
    final svc = makeSvc(client);
    await svc.uploadFile(f, isPrivate: false);
    expect(captured['is_private'], '0');
  });

  test('uploadFile returns raw response when no message envelope', () async {
    final client = MockClient.streaming((req, stream) async {
      await stream.toBytes();
      return http.StreamedResponse(
        Stream.value(utf8.encode(jsonEncode({'file_url': '/no-message'}))),
        200,
      );
    });
    final f = await _tempFile('hi', 'flat.txt');
    final svc = makeSvc(client);
    final out = await svc.uploadFile(f);
    expect(out['file_url'], '/no-message');
  });

  test('uploadFile throws NetworkException on TimeoutException', () async {
    final client = MockClient.streaming((req, stream) async {
      // never resolve to force a timeout
      await Future<void>.delayed(const Duration(seconds: 2));
      return http.StreamedResponse(const Stream.empty(), 200);
    });
    final rest = RestHelper(
      'http://x',
      client: client,
      uploadTimeout: const Duration(milliseconds: 50),
    );
    final svc = AttachmentService(rest);
    final f = await _tempFile('hi', 'slow.txt');
    await expectLater(svc.uploadFile(f), throwsA(isException));
  });

  test(
    'the multipart part carries the ORIGINAL filename, not the staged uuid',
    () async {
      // Frappe reassigns filename = file.filename whenever a file part is
      // present, so the multipart name — not form_dict.file_name — decides the
      // stored name. Staged files are named <uuid>.jpg, so passing the part
      // name through is the only thing that preserves "Site Photo.jpg".
      String? partFilename;
      final client = MockClient.streaming((req, stream) async {
        final body = utf8.decode(await stream.toBytes(), allowMalformed: true);
        partFilename = RegExp(
          r'name="file"; filename="([^"]+)"',
        ).firstMatch(body)?.group(1);
        return http.StreamedResponse(
          Stream.value(
            utf8.encode(
              jsonEncode({
                'message': {'file_url': '/x'},
              }),
            ),
          ),
          200,
        );
      });
      final f = await _tempFile('bytes', 'a1b2c3d4-uuid.jpg');
      await makeSvc(client).uploadFile(f, fileName: 'Site Photo.jpg');
      expect(partFilename, 'Site Photo.jpg');
    },
  );
}
