import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/api/doctype_service.dart';
import 'package:frappe_mobile_sdk/src/api/query_builder.dart';
import 'package:frappe_mobile_sdk/src/api/rest_helper.dart';
import 'package:http/http.dart' as http;

/// Minimal RestHelper stub; network is never actually used in these tests.
class _FakeRestHelper extends RestHelper {
  _FakeRestHelper() : super('https://fake.test', client: http.Client());
}

class _FakeDoctypeService extends DoctypeService {
  _FakeDoctypeService() : super(_FakeRestHelper());

  List<String>? lastFields;
  List<List<dynamic>>? lastFilters;
  int? lastLimitStart;
  int? lastLimitPageLength;
  String? lastOrderBy;

  @override
  Future<List<dynamic>> list(
    String doctype, {
    List<String>? fields,
    List<List<dynamic>>? filters,
    int limitStart = 0,
    int limitPageLength = 20,
    String? orderBy,
  }) async {
    lastFields = fields;
    lastFilters = filters;
    lastLimitStart = limitStart;
    lastLimitPageLength = limitPageLength;
    lastOrderBy = orderBy;
    return <dynamic>[];
  }
}

void main() {
  group('QueryBuilder', () {
    test('builds filters, fields, orderBy and limit correctly', () async {
      final service = _FakeDoctypeService();
      final qb = QueryBuilder(service, 'Customer')
          .select(<String>['name', 'customer_name'])
          .where('status', 'Open')
          .where('customer_group', 'like', '%Retail%')
          .orderBy('creation', descending: true)
          .limit(50, start: 100);

      await qb.get();

      expect(service.lastFields, <String>['name', 'customer_name']);
      expect(service.lastLimitStart, 100);
      expect(service.lastLimitPageLength, 50);
      expect(service.lastOrderBy, 'creation desc');

      expect(service.lastFilters, isNotNull);
      expect(service.lastFilters!.length, 2);

      // First filter: implicit '=' operator
      expect(service.lastFilters![0], <dynamic>[
        'Customer',
        'status',
        '=',
        'Open',
      ]);

      // Second filter: explicit operator
      expect(service.lastFilters![1], <dynamic>[
        'Customer',
        'customer_group',
        'like',
        '%Retail%',
      ]);
    });

    test('first() limits to 1', () async {
      final service = _FakeDoctypeService();
      final qb = QueryBuilder(service, 'Customer');

      await qb.first();

      expect(service.lastLimitPageLength, 1);
    });
  });
}
