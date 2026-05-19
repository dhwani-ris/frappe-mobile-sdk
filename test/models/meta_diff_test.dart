import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/meta_diff.dart';

void main() {
  test('MetaDiff.empty has no changes', () {
    const d = MetaDiff(
      doctype: 'X',
      addedFields: [],
      removedFields: [],
      typeChanged: [],
      addedIsLocalFor: [],
      addedNormFor: [],
      indexesToDrop: [],
    );
    expect(d.isNoOp, isTrue);
  });

  test('isNoOp false with any change', () {
    const d = MetaDiff(
      doctype: 'X',
      addedFields: [AddedField(name: 'age', sqlType: 'INTEGER')],
      removedFields: [],
      typeChanged: [],
      addedIsLocalFor: [],
      addedNormFor: [],
      indexesToDrop: [],
    );
    expect(d.isNoOp, isFalse);
  });
}
