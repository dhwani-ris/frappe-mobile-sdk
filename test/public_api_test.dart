import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';

void main() {
  test('ChildTableField and preserveChildIdentity are publicly exported', () {
    expect(ChildTableField, isNotNull);
    expect(
      preserveChildIdentity(const {'mobile_uuid': 'u1'}, const {'a': 1}),
      containsPair('mobile_uuid', 'u1'),
    );
  });
}
