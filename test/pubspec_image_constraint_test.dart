// The on-device photo shrink (`downscalePickedImage`) was written and tested
// against `image` 4.10.1. A wider constraint lets a host resolve an older
// 4.x that the suite never ran, so the lower bound is the tested version.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

List<int> _version(String v) => v.split('.').map(int.parse).toList();

int _compare(List<int> a, List<int> b) {
  for (var i = 0; i < 3; i++) {
    if (a[i] != b[i]) return a[i].compareTo(b[i]);
  }
  return 0;
}

void main() {
  const tested = '4.10.1';

  test('the image constraint starts at the tested version', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final m = RegExp(
      r'^  image: \^(\d+\.\d+\.\d+)\s*$',
      multiLine: true,
    ).firstMatch(pubspec);
    expect(m, isNotNull, reason: 'image is a caret dependency');
    final lower = m!.group(1)!;
    expect(
      _compare(_version(lower), _version(tested)),
      greaterThanOrEqualTo(0),
      reason: 'image: ^$lower admits versions older than $tested',
    );
  });

  test('the image version the suite resolves is admitted', () {
    final lock = File('pubspec.lock').readAsStringSync();
    final m = RegExp(
      r'^  image:\n(?:    .*\n)*?    version: "(\d+\.\d+\.\d+)"',
      multiLine: true,
    ).firstMatch(lock);
    expect(m, isNotNull);
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final lower = RegExp(
      r'^  image: \^(\d+\.\d+\.\d+)',
      multiLine: true,
    ).firstMatch(pubspec)!.group(1)!;
    final resolved = _version(m!.group(1)!);
    expect(_compare(resolved, _version(lower)), greaterThanOrEqualTo(0));
    expect(resolved.first, _version(lower).first, reason: 'same major as ^');
  });
}
