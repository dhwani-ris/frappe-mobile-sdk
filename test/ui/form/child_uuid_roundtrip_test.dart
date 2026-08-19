import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/child_table_field.dart';

// Task 1 (de-risk): editing a child row through the child-table sheet must not
// drop the row's local identity columns. The child FormController seeds
// _rawValues only for docfields (form_controller.dart:64), and buildSubmitData
// emits only _rawValues — so `mobile_uuid` (not a docfield) is dropped from the
// edited row unless it is explicitly preserved. `preserveChildIdentity` carries
// the identity columns from the pre-edit row onto the submitted row.
void main() {
  group('preserveChildIdentity', () {
    test('carries mobile_uuid from original when submitted lacks it', () {
      final original = {'mobile_uuid': 'CHILD-UUID-1', 'label': 'old'};
      final submitted = {'label': 'new'}; // child form dropped mobile_uuid

      final result = preserveChildIdentity(original, submitted);

      expect(result['mobile_uuid'], 'CHILD-UUID-1');
      expect(result['label'], 'new'); // edit preserved
    });

    test('carries server name too', () {
      final original = {
        'mobile_uuid': 'C1',
        'name': 'CHILD-0001',
        'label': 'x',
      };
      final submitted = {'label': 'x'};

      final result = preserveChildIdentity(original, submitted);

      expect(result['mobile_uuid'], 'C1');
      expect(result['name'], 'CHILD-0001');
    });

    test('does not overwrite an identity value the submit already has', () {
      final original = {'mobile_uuid': 'OLD'};
      final submitted = {'mobile_uuid': 'NEW', 'label': 'x'};

      final result = preserveChildIdentity(original, submitted);

      expect(result['mobile_uuid'], 'NEW');
    });

    test('new row (no original identity) stays clean', () {
      final original = <String, dynamic>{};
      final submitted = {'label': 'brand new'};

      final result = preserveChildIdentity(original, submitted);

      expect(result.containsKey('mobile_uuid'), isFalse);
      expect(result['label'], 'brand new');
    });
  });
}
