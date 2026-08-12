// Covers AttachField's "open attachment" path: how a stored value is classified
// (server URL vs local path, image vs other), the URL the download actually
// hits, the temp-cache naming, and the guard rails (timeout + size cap).
//
// IMPORTANT: no test here may reach OpenFilex.open. On a non-iOS/Android host
// open_filex shells out to `open`/`xdg-open`, which would launch a real
// application on the developer's machine (and throws ProcessException on CI).
// Every download test therefore ends in an error branch, and the local-file
// branch (which calls OpenFilex directly) is intentionally not exercised — it
// needs a device.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/attach_field.dart';
import 'package:http/http.dart' as http;

/// Records every request and answers with whatever the test supplies.
class _FakeClient extends http.BaseClient {
  _FakeClient(this._handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest) _handler;
  final List<http.BaseRequest> requests = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests.add(request);
    return _handler(request);
  }
}

http.StreamedResponse _response({
  int status = 200,
  int? contentLength,
  Stream<List<int>>? body,
}) {
  return http.StreamedResponse(
    body ?? const Stream<List<int>>.empty(),
    status,
    contentLength: contentLength,
  );
}

Future<void> _pump(
  WidgetTester tester, {
  required dynamic value,
  required _FakeClient client,
  String? fileUrlBase,
  Map<String, String>? headers,
  DocField? field,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: FormBuilder(
          key: GlobalKey<FormBuilderState>(),
          child: AttachField(
            field:
                field ??
                DocField(
                  fieldname: 'doc',
                  fieldtype: 'Attach',
                  label: 'Document',
                ),
            value: value,
            fileUrlBase: fileUrlBase,
            imageHeaders: headers,
            httpClient: client,
          ),
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('attachmentTempFileName', () {
    const proxy =
        'https://erp.example.com/api/method/'
        'frappe.handler.download_file?file_url=';

    test('two URLs sharing a basename get different cache files', () {
      final a = attachmentTempFileName(
        '$proxy%2Ffiles%2Freport.pdf',
        'report.pdf',
      );
      final b = attachmentTempFileName(
        '$proxy%2Fprivate%2Ffiles%2Freport.pdf',
        'report.pdf',
      );
      expect(a, isNot(b));
      expect(a, endsWith('.pdf'));
      expect(b, endsWith('.pdf'));
    });

    test('same URL always maps to the same cache file', () {
      const url = '$proxy%2Ffiles%2Freport.pdf';
      expect(
        attachmentTempFileName(url, 'report.pdf'),
        attachmentTempFileName(url, 'report.pdf'),
      );
    });

    test('extension comes from the stored basename for proxy URLs', () {
      // The proxy URL path is `/api/method/frappe.handler.download_file`, whose
      // own "extension" (.download_file) must not win over the real name.
      final name = attachmentTempFileName(
        '$proxy%2Ffiles%2Freport.pdf',
        'report.pdf',
      );
      expect(name, endsWith('.pdf'));
    });

    test('falls back to the URL path, ignoring the query string', () {
      expect(
        attachmentTempFileName('https://cdn.example.com/a.pdf?token=abc', ''),
        endsWith('.pdf'),
      );
      expect(
        attachmentTempFileName('https://cdn.example.com/a.docx', 'a'),
        endsWith('.docx'),
      );
    });

    test('no extension anywhere leaves the name extensionless', () {
      final name = attachmentTempFileName(
        'https://erp.example.com/api/method/handler',
        '',
      );
      expect(name, isNot(contains('.')));
    });

    test('only short alphanumeric extensions survive', () {
      // A too-long "extension" and a traversal attempt must both be dropped, so
      // the name can never escape the cache directory.
      for (final bogus in ['x.tooooolongextension', 'x./../../etc/passwd']) {
        final name = attachmentTempFileName(
          'https://erp.example.com/api/method/handler',
          bogus,
        );
        expect(name, matches(RegExp(r'^[0-9a-f]{40}$')));
      }
    });

    test('name is always a hex digest plus an optional safe extension', () {
      final name = attachmentTempFileName(
        'https://cdn.example.com/deep/path/File.PDF',
        'File.PDF',
      );
      expect(name, matches(RegExp(r'^[0-9a-f]{40}\.pdf$')));
    });
  });

  group('classification (through the widget)', () {
    testWidgets('/private/files/ downloads via the download_file proxy with '
        'auth headers', (tester) async {
      // Over-cap content-length so the flow ends before any disk/OpenFilex work.
      final client = _FakeClient(
        (_) async => _response(contentLength: 60 * 1024 * 1024),
      );
      await _pump(
        tester,
        value: '/private/files/report.pdf',
        client: client,
        fileUrlBase: 'http://example.com/',
        headers: const {'Authorization': 'Bearer tok'},
      );
      await tester.tap(find.byIcon(Icons.open_in_new));
      await tester.pumpAndSettle();

      expect(client.requests, hasLength(1));
      expect(
        client.requests.single.url.toString(),
        'http://example.com/api/method/frappe.handler.download_file'
        '?file_url=%2Fprivate%2Ffiles%2Freport.pdf',
      );
      expect(client.requests.single.headers['Authorization'], 'Bearer tok');
    });

    testWidgets(
      'a relative /api/method/ proxy URL is treated as a server URL',
      (tester) async {
        final client = _FakeClient(
          (_) async => _response(contentLength: 60 * 1024 * 1024),
        );
        await _pump(
          tester,
          value:
              '/api/method/multi_cloud_storage.controller.generate_file'
              '?key=abc.pdf',
          client: client,
          fileUrlBase: 'http://example.com',
        );
        await tester.tap(find.byIcon(Icons.open_in_new));
        await tester.pumpAndSettle();

        // A local path would have gone straight to OpenFilex with no request.
        expect(client.requests, hasLength(1));
        expect(
          client.requests.single.url.toString(),
          'http://example.com/api/method/'
          'multi_cloud_storage.controller.generate_file?key=abc.pdf',
        );
      },
    );

    testWidgets('an image URL with a query string opens the viewer, not a '
        'download', (tester) async {
      final client = _FakeClient((_) async => _response());
      await _pump(
        tester,
        value: 'https://cdn.example.com/photo.png?token=abc',
        client: client,
      );
      // Image attachments show the "view" affordance, not "open externally".
      expect(find.byIcon(Icons.visibility), findsOneWidget);
      expect(find.byIcon(Icons.open_in_new), findsNothing);

      await tester.tap(find.byIcon(Icons.visibility));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(Dialog), findsOneWidget);
      expect(client.requests, isEmpty);
      // The viewer's NetworkImage cannot load in the test harness; discard the
      // image-load error it reports so it is not mistaken for a failure here.
      tester.takeException();
    });

    testWidgets('a non-image attachment shows the open-externally affordance', (
      tester,
    ) async {
      final client = _FakeClient((_) async => _response());
      await _pump(tester, value: '/files/report.pdf', client: client);
      expect(find.byIcon(Icons.open_in_new), findsOneWidget);
      expect(find.byIcon(Icons.visibility), findsNothing);
    });
  });

  group('download guard rails', () {
    late Directory tempRoot;
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');

    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync('attach_field_test');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProvider, (call) async {
            if (call.method == 'getTemporaryDirectory') return tempRoot.path;
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProvider, null);
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    });

    testWidgets('a hung server surfaces a timeout message and clears the '
        'spinner', (tester) async {
      // Never completes — the old code had no timeout, so the spinner stayed up
      // forever with no way out.
      final client = _FakeClient(
        (_) => Completer<http.StreamedResponse>().future,
      );
      await _pump(
        tester,
        value: '/files/report.pdf',
        client: client,
        fileUrlBase: 'http://example.com',
      );
      await tester.tap(find.byIcon(Icons.open_in_new));
      await tester.pump();
      // Busy spinner while the request is in flight.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await tester.pump(const Duration(seconds: 31));
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.textContaining('timed out'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byIcon(Icons.open_in_new), findsOneWidget);
    });

    testWidgets('a declared content-length over the cap is refused with a '
        'message', (tester) async {
      final client = _FakeClient(
        (_) async => _response(contentLength: 200 * 1024 * 1024),
      );
      await _pump(
        tester,
        value: '/files/huge.pdf',
        client: client,
        fileUrlBase: 'http://example.com',
      );
      await tester.tap(find.byIcon(Icons.open_in_new));
      await tester.pumpAndSettle();

      expect(find.textContaining('too large'), findsOneWidget);
      // Refused before anything was written to disk.
      expect(
        Directory('${tempRoot.path}/frappe_attachments').existsSync(),
        isFalse,
      );
    });

    testWidgets('a body over the cap is aborted even without a content-length', (
      tester,
    ) async {
      // One oversized chunk: the running byte count (not the header) is what
      // stops it, and it stops before the bytes are written.
      final client = _FakeClient(
        (_) async => _response(
          body: Stream<List<int>>.value(Uint8List(51 * 1024 * 1024)),
        ),
      );
      await _pump(
        tester,
        value: '/files/chunked.pdf',
        client: client,
        fileUrlBase: 'http://example.com',
      );
      await tester.tap(find.byIcon(Icons.open_in_new));
      // This branch reaches the real filesystem (temp dir, sink, cleanup). Real
      // dart:io futures only complete outside the test's FakeAsync clock, while
      // the widget's own continuations only run when the fake clock is pumped —
      // so the two have to be alternated until the flow finishes.
      final refused = find.textContaining('too large');
      for (var i = 0; i < 50 && refused.evaluate().isEmpty; i++) {
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.textContaining('too large'), findsOneWidget);
      // Downloads live in their own subdirectory, and the partial file is gone.
      final cacheDir = Directory('${tempRoot.path}/frappe_attachments');
      expect(cacheDir.existsSync(), isTrue);
      expect(cacheDir.listSync(), isEmpty);
    });

    testWidgets('a non-200 response reports the status code', (tester) async {
      final client = _FakeClient((_) async => _response(status: 404));
      await _pump(
        tester,
        value: '/files/missing.pdf',
        client: client,
        fileUrlBase: 'http://example.com',
      );
      await tester.tap(find.byIcon(Icons.open_in_new));
      await tester.pumpAndSettle();

      expect(find.textContaining('HTTP 404'), findsOneWidget);
    });
  });
}
