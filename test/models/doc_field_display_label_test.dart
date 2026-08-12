import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';

/// `displayLabel` runs on widget build paths, so its zero-width strip pattern
/// is a hoisted `static final RegExp`. These tests pin the OBSERVABLE contract
/// (which string comes out for each label shape) so the hoist — and any future
/// tweak to the pattern — cannot silently change what a form renders or what a
/// required-validation message reads.
void main() {
  group('DocField.displayLabel', () {
    test('a real label passes through unchanged', () {
      final field = DocField(
        fieldname: 'lead_name',
        fieldtype: 'Data',
        label: 'Lead Name',
      );
      expect(field.displayLabel, 'Lead Name');
    });

    test('a null label humanizes the fieldname', () {
      final field = DocField(fieldname: 'entrepreneur_name', fieldtype: 'Data');
      expect(field.displayLabel, 'Entrepreneur Name');
    });

    test('a single-word fieldname is capitalized', () {
      final field = DocField(fieldname: 'email', fieldtype: 'Data');
      expect(field.displayLabel, 'Email');
    });

    test('a zero-width-only label humanizes the fieldname', () {
      // Hosts set a blank label to '​' to suppress duplicate rendering;
      // treating it as present degrades the message to a bare "is required".
      final field = DocField(
        fieldname: 'entrepreneur_name',
        fieldtype: 'Data',
        label: '​',
      );
      expect(field.displayLabel, 'Entrepreneur Name');
    });

    test('every stripped zero-width codepoint is treated as blank', () {
      const zeroWidth = <String, String>{
        '​': 'U+200B ZERO WIDTH SPACE',
        '‌': 'U+200C ZERO WIDTH NON-JOINER',
        '‍': 'U+200D ZERO WIDTH JOINER',
        '﻿': 'U+FEFF BOM',
      };
      zeroWidth.forEach((char, name) {
        final field = DocField(
          fieldname: 'total_amount',
          fieldtype: 'Currency',
          label: '$char$char',
        );
        expect(field.displayLabel, 'Total Amount', reason: 'label was $name');
      });
    });

    test('an empty label humanizes the fieldname', () {
      final field = DocField(
        fieldname: 'total_amount',
        fieldtype: 'Currency',
        label: '',
      );
      expect(field.displayLabel, 'Total Amount');
    });

    test('a whitespace-only label humanizes the fieldname', () {
      final field = DocField(
        fieldname: 'total_amount',
        fieldtype: 'Currency',
        label: '   ',
      );
      expect(field.displayLabel, 'Total Amount');
    });

    test('a zero-width character mixed with real text keeps the label', () {
      // The strip is only a non-emptiness PROBE — the original label (zero
      // width char included) is what gets returned, not the stripped copy.
      final field = DocField(
        fieldname: 'total_amount',
        fieldtype: 'Currency',
        label: '​Total',
      );
      expect(field.displayLabel, '​Total');
    });

    test('null label and null fieldname yields an empty string', () {
      final field = DocField(fieldtype: 'Data');
      expect(field.displayLabel, '');
    });

    test('blank label and empty fieldname yields an empty string', () {
      final field = DocField(fieldname: '', fieldtype: 'Data', label: '​');
      expect(field.displayLabel, '');
    });

    test('repeated calls return the same value (pattern is stateless)', () {
      final field = DocField(
        fieldname: 'entrepreneur_name',
        fieldtype: 'Data',
        label: '​',
      );
      // A RegExp shared across calls must not carry match state between them.
      expect(field.displayLabel, 'Entrepreneur Name');
      expect(field.displayLabel, 'Entrepreneur Name');
      expect(field.displayLabel, 'Entrepreneur Name');
    });

    test('leading/trailing underscores do not produce empty segments', () {
      final field = DocField(fieldname: '_custom__flag_', fieldtype: 'Check');
      expect(field.displayLabel, 'Custom Flag');
    });
  });
}
