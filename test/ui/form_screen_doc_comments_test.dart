// The doc comments at the top of form_screen.dart document the declaration
// right below them. A merge once left the stall-timeout explanation of
// `readCappedMediaBody` above `mediaFetchRequest`, and the `FormScreenStyle`
// summary above a private constant, so both read wrong in the API docs.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The `///` lines directly above the first line matching [declaration],
/// skipping annotations, joined with newlines.
String docAbove(List<String> src, RegExp declaration) {
  final at = src.indexWhere(declaration.hasMatch);
  expect(at, isNonNegative, reason: 'declaration $declaration not found');
  var i = at - 1;
  while (i >= 0 && src[i].trimLeft().startsWith('@')) {
    i--;
  }
  final doc = <String>[];
  while (i >= 0 && src[i].trimLeft().startsWith('///')) {
    doc.insert(0, src[i].trim());
    i--;
  }
  return doc.join('\n');
}

void main() {
  final src = File('lib/src/ui/form_screen.dart').readAsLinesSync();

  test('readCappedMediaBody carries its own doc comment', () {
    final doc = docAbove(
      src,
      RegExp(r'^Future<List<int>\?> readCappedMediaBody\('),
    );
    expect(doc, startsWith("/// Accumulates [res]'s body"));
    expect(doc, contains('The stall bound is per-CHUNK'));
  });

  test('mediaFetchRequest is documented only as the request it builds', () {
    final doc = docAbove(src, RegExp(r'^http\.Request\? mediaFetchRequest\('));
    expect(doc, startsWith('/// The GET request the media resolver'));
    expect(doc, isNot(contains('stall')));
  });

  test('FormScreenStyle and the connect timeout have their own summaries', () {
    expect(
      docAbove(src, RegExp(r'^class FormScreenStyle\b')),
      '/// Visual customization for [FormScreen] action area.',
    );
    expect(
      docAbove(src, RegExp(r'^const Duration _mediaFetchConnectTimeout\b')),
      '/// Bound on the connect/headers phase of a media fetch.',
    );
  });
}
