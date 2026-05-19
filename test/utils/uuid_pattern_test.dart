import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/utils/uuid_pattern.dart';

void main() {
  group('looksLikeMobileUuid', () {
    test('matches canonical lowercase v4 UUIDs', () {
      expect(
        looksLikeMobileUuid('a3102819-2bfe-43bd-a4b7-ae8c2c242a34'),
        isTrue,
      );
      expect(
        looksLikeMobileUuid('0feb9d50-f2c6-4dd1-9b56-495919dc933d'),
        isTrue,
      );
    });

    test('matches uppercase + mixed-case UUIDs', () {
      expect(
        looksLikeMobileUuid('A3102819-2BFE-43BD-A4B7-AE8C2C242A34'),
        isTrue,
      );
      expect(
        looksLikeMobileUuid('A3102819-2bfe-43BD-a4b7-AE8C2C242a34'),
        isTrue,
      );
    });

    test('tolerates surrounding whitespace', () {
      expect(
        looksLikeMobileUuid('  a3102819-2bfe-43bd-a4b7-ae8c2c242a34  '),
        isTrue,
      );
    });

    test('rejects null, empty, and whitespace', () {
      expect(looksLikeMobileUuid(null), isFalse);
      expect(looksLikeMobileUuid(''), isFalse);
      expect(looksLikeMobileUuid('   '), isFalse);
    });

    test('rejects Frappe naming-series style server names', () {
      expect(looksLikeMobileUuid('HSFM-2026-00042'), isFalse);
      expect(looksLikeMobileUuid('SPMIS-00200'), isFalse);
      expect(looksLikeMobileUuid('CUST-001'), isFalse);
      expect(looksLikeMobileUuid('Order-2026-04-001'), isFalse);
    });

    test('rejects Frappe hash autoname (10-char hex token, no dashes)', () {
      expect(looksLikeMobileUuid('abc123def4'), isFalse);
      expect(looksLikeMobileUuid('1234567890abcdef'), isFalse);
    });

    test('rejects partial / malformed UUIDs', () {
      // Missing a section
      expect(looksLikeMobileUuid('a3102819-2bfe-43bd-a4b7'), isFalse);
      // Wrong section length
      expect(
        looksLikeMobileUuid('a310281-2bfe-43bd-a4b7-ae8c2c242a34'),
        isFalse,
      );
      // Non-hex characters
      expect(
        looksLikeMobileUuid('z3102819-2bfe-43bd-a4b7-ae8c2c242a34'),
        isFalse,
      );
      // Suffixed
      expect(
        looksLikeMobileUuid('a3102819-2bfe-43bd-a4b7-ae8c2c242a34-extra'),
        isFalse,
      );
    });

    test('rejects email-shaped owners (Frappe `owner` field values)', () {
      expect(looksLikeMobileUuid('user@example.com'), isFalse);
    });
  });
}
