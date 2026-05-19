import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/sync/payload_serializer.dart';

DocTypeMeta _meta() => DocTypeMeta(
  name: 'Customer',
  isTable: false,
  fields: [
    DocField(fieldname: 'customer_name', fieldtype: 'Data'),
    DocField(fieldname: 'amount', fieldtype: 'Currency'),
    DocField(fieldname: 'territory', fieldtype: 'Link', options: 'Territory'),
  ],
);

void main() {
  test('drops every system column', () {
    final row = <String, Object?>{
      'mobile_uuid': 'u1',
      'server_name': null,
      'sync_status': 'dirty',
      'sync_error': null,
      'sync_attempts': 0,
      'sync_op': 'INSERT',
      'error_code': null,
      'last_attempt_at': null,
      'push_base_payload': null,
      'docstatus': 0,
      'modified': null,
      'local_modified': 1700000000000,
      'pulled_at': null,
      'customer_name': 'Acme',
      'amount': 42.0,
      'territory': 'India',
    };
    final out = PayloadSerializer.serializeForBase(row, _meta());
    expect(out.keys.toSet(), {
      'docstatus',
      'modified',
      'customer_name',
      'amount',
      'territory',
    });
  });

  test('drops __norm and __is_local companion columns', () {
    final row = <String, Object?>{
      'mobile_uuid': 'u1',
      'sync_status': 'dirty',
      'local_modified': 1,
      'customer_name': 'Acme',
      'customer_name__norm': 'acme',
      'territory': 'India',
      'territory__is_local': 0,
    };
    final out = PayloadSerializer.serializeForBase(row, _meta());
    expect(out.containsKey('customer_name__norm'), isFalse);
    expect(out.containsKey('territory__is_local'), isFalse);
    expect(out['customer_name'], 'Acme');
    expect(out['territory'], 'India');
  });

  test('keeps user fields declared on meta', () {
    final row = <String, Object?>{
      'mobile_uuid': 'u1',
      'sync_status': 'dirty',
      'local_modified': 1,
      'customer_name': 'Acme',
      'amount': 100.0,
    };
    final out = PayloadSerializer.serializeForBase(row, _meta());
    expect(out['customer_name'], 'Acme');
    expect(out['amount'], 100.0);
  });

  test('returns empty map when only system columns present', () {
    final row = <String, Object?>{
      'mobile_uuid': 'u1',
      'sync_status': 'dirty',
      'sync_attempts': 0,
      'local_modified': 1,
    };
    final out = PayloadSerializer.serializeForBase(row, _meta());
    expect(out, isEmpty);
  });
}
