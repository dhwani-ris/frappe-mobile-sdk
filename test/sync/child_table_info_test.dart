import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/sync/child_table_info.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';

void main() {
  test('tableName normalizes doctype name via normalizeDoctypeTableName', () {
    final meta = DocTypeMeta(
      name: 'Sales Order Item',
      isTable: true,
      fields: const [],
    );
    final info = ChildTableInfo('Sales Order Item', meta);
    expect(info.tableName, 'docs__sales_order_item');
    expect(info.doctype, 'Sales Order Item');
    expect(info.meta, same(meta));
  });
}
