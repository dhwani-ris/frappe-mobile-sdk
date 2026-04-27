import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/sync/uuid_rewriter.dart';
import 'package:frappe_mobile_sdk/src/sync/push_error.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';

DocField f(String n, String t, {String? options}) =>
    DocField(fieldname: n, fieldtype: t, label: n, options: options);

class _FakeResolver {
  final Map<String, Map<String, String>> table; // doctype → uuid → server_name
  _FakeResolver(this.table);
  Future<String?> call(String doctype, String uuid) async {
    return table[doctype]?[uuid];
  }
}

void main() {
  test('replaces local Link values with server_name', () async {
    final meta = DocTypeMeta(name: 'Sales Order', fields: [
      f('customer', 'Link', options: 'Customer'),
      f('warehouse', 'Link', options: 'Warehouse'),
    ]);
    final payload = <String, Object?>{
      'customer': 'u-cust-1', 'customer__is_local': 1,
      'warehouse': 'WH-1', 'warehouse__is_local': 0,
    };
    final resolver = _FakeResolver({
      'Customer': {'u-cust-1': 'CUST-101'},
    });
    final out = await UuidRewriter.rewrite(
      meta: meta,
      payload: payload,
      resolveServerName: resolver.call,
    );
    expect(out['customer'], 'CUST-101');
    expect(out['warehouse'], 'WH-1');
    expect(out.containsKey('customer__is_local'), isFalse,
        reason: '__is_local markers dropped from outbound payload');
    expect(out.containsKey('warehouse__is_local'), isFalse);
  });

  test('unresolved target throws BlockedByUpstream', () async {
    final meta = DocTypeMeta(name: 'SO', fields: [
      f('customer', 'Link', options: 'Customer'),
    ]);
    final payload = <String, Object?>{
      'customer': 'u-new', 'customer__is_local': 1,
    };
    final resolver = _FakeResolver({'Customer': {}});
    await expectLater(
      UuidRewriter.rewrite(
        meta: meta,
        payload: payload,
        resolveServerName: resolver.call,
      ),
      throwsA(isA<BlockedByUpstream>()),
    );
  });

  test('nested children — rewrites inside each child row', () async {
    final parentMeta = DocTypeMeta(name: 'SO', fields: [
      f('items', 'Table', options: 'SO Item'),
    ]);
    final childMeta = DocTypeMeta(
      name: 'SO Item',
      isTable: true,
      fields: [f('product', 'Link', options: 'Product')],
    );
    final payload = <String, Object?>{
      'items': [
        {'product': 'u-prod-1', 'product__is_local': 1, 'qty': 1},
      ],
    };
    final resolver = _FakeResolver({
      'Product': {'u-prod-1': 'P-42'},
    });
    final out = await UuidRewriter.rewrite(
      meta: parentMeta,
      payload: payload,
      resolveServerName: resolver.call,
      childMetasByFieldname: {'items': childMeta},
    );
    final items = out['items'] as List;
    expect(items.first['product'], 'P-42');
    expect((items.first as Map).containsKey('product__is_local'), isFalse);
  });

  test('Dynamic Link — rewrites using sibling-resolved doctype', () async {
    final meta = DocTypeMeta(name: 'Comment', fields: [
      f('reference_name', 'Dynamic Link', options: 'reference_doctype'),
    ]);
    final payload = <String, Object?>{
      'reference_doctype': 'Customer',
      'reference_name': 'u-cust-1',
      'reference_name__is_local': 1,
    };
    final resolver = _FakeResolver({
      'Customer': {'u-cust-1': 'CUST-9'},
    });
    final out = await UuidRewriter.rewrite(
      meta: meta,
      payload: payload,
      resolveServerName: resolver.call,
    );
    expect(out['reference_name'], 'CUST-9');
  });

  test('non-local Link values pass through untouched', () async {
    final meta = DocTypeMeta(name: 'SO', fields: [
      f('customer', 'Link', options: 'Customer'),
    ]);
    final payload = <String, Object?>{
      'customer': 'CUST-EXISTING',
      'customer__is_local': 0,
    };
    final out = await UuidRewriter.rewrite(
      meta: meta,
      payload: payload,
      resolveServerName: (_, __) async =>
          fail('resolver should not be called for non-local'),
    );
    expect(out['customer'], 'CUST-EXISTING');
  });
}
