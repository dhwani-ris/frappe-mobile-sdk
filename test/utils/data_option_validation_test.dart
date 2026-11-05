import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';
import 'package:frappe_mobile_sdk/src/utils/data_option_validation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A Data field with options Email, Phone, Name or URL is checked by Frappe
/// on save (`BaseDocument._validate_data_fields`). Offline, the SDK only hears
/// that at sync, so the form checks it with the same rules first.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  String? e(String options, String? value) => dataOptionError(options, value);

  test('Email: each address in the list must be valid', () {
    expect(e('Email', 'person@example.com'), isNull);
    expect(e('Email', 'a@example.com, b@example.org'), isNull);
    expect(e('Email', 'Person <person@example.com>'), isNull);
    expect(e('Email', 'abc'), 'abc is not a valid Email Address');
    expect(e('Email', 'a@example.com, nope'), isNotNull);
  });

  test('Phone: digits and + - _ , . * # ( ) spaces, up to 20', () {
    expect(e('Phone', '+91 98765-43210'), isNull);
    expect(e('Phone', '98765abc'), '98765abc is not a valid Phone Number');
    expect(e('Phone', '1' * 21), isNotNull);
  });

  test('Name: letters and numbers of any script, apostrophes and hyphens', () {
    expect(e('Name', "Anne-Marie O'Neil"), isNull);
    expect(e('Name', '李小龙'), isNull);
    expect(e('Name', 'Bad  Name!'), isNotNull);
  });

  test('URL: a scheme with a host or path, or a site path', () {
    expect(e('URL', 'https://example.com/a?b=1'), isNull);
    expect(e('URL', '/files/report.pdf'), isNull);
    expect(e('URL', 'not a url'), "'not a url' is not a valid URL");
  });

  test('empty values and other options are not checked', () {
    expect(e('Email', ''), isNull);
    expect(e('Name', null), isNull);
    expect(e('Barcode', 'anything'), isNull);
  });

  // What Frappe's own validators answer, recorded by executing
  // frappe/utils/__init__.py (version-15) as `_validate_data_fields` calls it
  // (split_emails + validate_email_address, validate_name,
  // validate_phone_number, validate_url). true = the save goes through.
  const frappeVerdicts = <String, Map<String, bool>>{
    'Email': {
      'person@example.com': true,
      'a@example.com, b@example.org': true,
      'Person <person@example.com>': true,
      '"Doe John" <john@example.com>': true,
      // validate_email_address splits on every comma, quoted or not.
      '"Doe, John" <john@example.com>': false,
      'Doe, John <john@example.com>': false,
      // Line breaks and tabs become spaces before the list is split.
      'a@example.com\nb@example.org': false,
      'a@example.com\tb@example.org': false,
      'a@example.com,': true,
      'a@example.com,,b@example.org': true,
      // EMAIL_MATCH_PATTERN is applied with re.match: anchored at the start.
      'a@example.com.': true,
      'a@example.com!!': true,
      'a@example.com>': true,
      // email.utils.parseaddr unwraps these before the check.
      '"a@example.com"': true,
      'mailto:a@example.com': true,
      'a@example.com;b@example.org': true,
      'undisclosed-recipients:;': true,
      'a@b.c': true,
      // re.IGNORECASE: [a-z] also matches U+212A KELVIN SIGN and U+017F.
      '\u212Aa@example.com': true,
      '\u017Fa@example.com': true,
      'a@example.com b@example.org': false,
      'a@example.com (Work)': false,
      'person@localhost': false,
      'élise@example.com': false,
      'ßa@example.com': false,
      'Person <bad>': false,
      'a..b@example.com': false,
      '   ': true,
    },
    'Name': {
      "Anne-Marie O'Neil": true,
      'Kishor': true,
      'अमर': true,
      '李小龙': true,
      'محمد علي': true,
      'Ελένη': true,
      // Precomposed U+00E9.
      'Jos\u00e9': true,
      ' Padded ': true,
      // Python's \w does not match a combining mark (vowel sign, virama,
      // combining accent), so Frappe refuses these names.
      'किशोर': false,
      'प्रिया': false,
      'राम कुमार': false,
      'தமிழ்': false,
      // e + U+0301 COMBINING ACUTE ACCENT, e + U+0308 COMBINING DIAERESIS.
      'Jose\u0301': false,
      'Zoe\u0308': false,
      'Bad  Name!': false,
      "'OBrien": false,
      'Dr. Smith': false,
      '   ': false,
    },
    'URL': {
      'https://example.com/a?b=1': true,
      '/files/report.pdf': true,
      'foo:bar': true,
      'mailto:a@example.com': true,
      'http://exa mple.com': true,
      ' https://example.com': true,
      'http:x;y': true,
      'localhost:8000': true,
      'not a url': false,
      'http://': false,
      'www.example.com': false,
      '1abc:x': false,
      'a_b:x': false,
      'http:;x': false,
      'http://[abc': false,
      '?q=1': false,
      '   ': false,
    },
    'Phone': {
      '+91 98765-43210': true,
      '(011) 2345 6789': true,
      '98765abc': false,
      '+1-800-FLOWERS': false,
      '   ': false,
    },
  };

  frappeVerdicts.forEach((option, cases) {
    test('$option: accepts and refuses what Frappe does', () {
      cases.forEach((value, accepted) {
        expect(
          e(option, value),
          accepted ? isNull : isNotNull,
          reason:
              '${jsonEncode(value)}: Frappe '
              '${accepted ? 'accepts' : 'refuses'} it',
        );
      });
    });
  });

  test('the message names the part Frappe names', () {
    expect(
      e('Email', '"Doe, John" <john@example.com>'),
      '"Doe is not a valid Email Address',
    );
    expect(
      e('Email', 'a@example.com\nb@example.org'),
      'a@example.com b@example.org is not a valid Email Address',
    );
    expect(e('Name', 'किशोर'), 'किशोर is not a valid Name');
    expect(e('URL', 'http:;x'), "'http:;x' is not a valid URL");
  });

  for (final mode in FormBuilderMode.values) {
    testWidgets('$mode: an invalid email blocks the save', (tester) async {
      Map<String, dynamic>? out;
      void Function()? submit;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FrappeFormBuilder(
              meta: DocTypeMeta(
                name: 'Contact Entry',
                fields: [
                  DocField(
                    fieldname: 'email',
                    fieldtype: 'Data',
                    options: 'Email',
                    label: 'Email',
                  ),
                ],
              ),
              mode: mode,
              onSubmit: (d) => out = d,
              registerSubmit: (fn) => submit = fn,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('data_email')), 'abc');
      await tester.pumpAndSettle();
      submit!();
      await tester.pumpAndSettle();
      expect(out, isNull);
      expect(find.text('abc is not a valid Email Address'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('data_email')),
        'person@example.com',
      );
      await tester.pumpAndSettle();
      submit!();
      await tester.pumpAndSettle();
      expect(out?['email'], 'person@example.com');
    });
  }
}
