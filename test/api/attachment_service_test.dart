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
      expect(captured['filename'], 'note.txt');
      expect(captured.containsKey('dt'), isFalse);
      expect(captured.containsKey('dn'), isFalse);
    },
  );

  test(
    'uploadFile attaches dt + dn when both doctype and docname given',
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
      expect(captured['dt'], 'Customer');
      expect(captured['dn'], 'CUST-1');
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
}
