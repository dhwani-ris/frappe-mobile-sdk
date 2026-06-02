import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/utils/aadhaar_validator.dart';


void main() {
  group('AadhaarValidator Tests', () {
    test('Geçerli bir Aadhaar numarası true dönmeli', () {
      expect(AadhaarValidator.isValid('234567890123'), isTrue);
    });

    test('Boşluk veya tire içeren geçerli numara true dönmeli', () {
      expect(AadhaarValidator.isValid('2345 6789 0123'), isTrue);
      expect(AadhaarValidator.isValid('2345-6789-0123'), isTrue);
    });

    test('12 haneden eksik veya fazla olanlar false dönmeli', () {
      expect(AadhaarValidator.isValid('23456789012'), isFalse); // 11 hane
      expect(AadhaarValidator.isValid('2345678901234'), isFalse); // 13 hane
    });

    test('0 veya 1 ile başlayan numaralar false dönmeli', () {
      expect(AadhaarValidator.isValid('034567890123'), isFalse);
      expect(AadhaarValidator.isValid('134567890123'), isFalse);
    });

    test('Boş veya null değerler false dönmeli', () {
      expect(AadhaarValidator.isValid(''), isFalse);
      expect(AadhaarValidator.isValid(null), isFalse);
    });
  });
}
