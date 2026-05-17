import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';

void main() {
  test('PayloadTransformerFn typedef is exported from the SDK barrel', () {
    // Smoke test: typedef must be importable from package consumer.
    Map<String, dynamic> identity(
      String doctype,
      Map<String, dynamic> payload,
      DocTypeMeta meta,
    ) => payload;
    final PayloadTransformerFn f = identity;
    expect(f, isNotNull);
  });

  test('transformer fn receives doctype, payload, meta and returns map', () {
    Map<String, dynamic>? captured;
    Map<String, dynamic> fn(
      String doctype,
      Map<String, dynamic> payload,
      DocTypeMeta meta,
    ) {
      captured = payload;
      return {...payload, 'docstatus': 1};
    }

    final meta = DocTypeMeta(
      name: 'X',
      label: 'X',
      isTable: false,
      titleField: null,
      searchFields: null,
      fields: const [],
    );
    final out = fn('X', {'foo': 'bar'}, meta);

    expect(captured, {'foo': 'bar'});
    expect(out, {'foo': 'bar', 'docstatus': 1});
  });
}
