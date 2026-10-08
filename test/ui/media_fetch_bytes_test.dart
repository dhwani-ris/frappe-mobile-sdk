// `FormScreen._fetchMediaBytes` returned `readCappedMediaBody(...)` from inside
// `try` without awaiting it. The `finally` then closed the HTTP client while
// the body was still streaming, which aborts a real connection, and the
// resulting error escaped the `catch`. The fetch now lives in
// [fetchMediaBytes], which awaits the body before the client is closed.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/ui/form_screen.dart';
import 'package:http/http.dart' as http;

/// Streams its body a chunk at a time, and aborts it when closed, the way
/// `IOClient.close` drops an open connection.
class _AbortOnCloseClient extends http.BaseClient {
  final _body = StreamController<List<int>>();
  var closedBeforeBodyEnded = false;
  var _bodyEnded = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    () async {
      for (var i = 0; i < 3; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        if (_body.isClosed) return;
        _body.add([i, i, i]);
      }
      _bodyEnded = true;
      await _body.close();
    }();
    return http.StreamedResponse(_body.stream, 200);
  }

  @override
  void close() {
    if (!_bodyEnded) {
      closedBeforeBodyEnded = true;
      _body.addError(http.ClientException('connection closed'));
      _body.close();
    }
  }
}

void main() {
  test('the whole body is read before the client is closed', () async {
    final client = _AbortOnCloseClient();
    final bytes = await fetchMediaBytes(
      '/files/a.jpg',
      baseUrl: 'https://site.example.com',
      headers: const {},
      newClient: () => client,
    );
    expect(client.closedBeforeBodyEnded, isFalse);
    expect(bytes, [0, 0, 0, 1, 1, 1, 2, 2, 2]);
  });

  test('a value that is not a fetchable URL is not fetched', () async {
    var created = false;
    final bytes = await fetchMediaBytes(
      'pending:abc',
      baseUrl: 'https://site.example.com',
      headers: const {},
      newClient: () {
        created = true;
        return _AbortOnCloseClient();
      },
    );
    expect(bytes, isNull);
    expect(created, isFalse);
  });
}
