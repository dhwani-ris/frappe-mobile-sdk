import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/query/parsed_query.dart';

void main() {
  test('toString formats sql and params', () {
    const q = ParsedQuery(
      sql: 'SELECT * FROM docs__customer WHERE status = ?',
      params: ['Active'],
    );
    expect(
      q.toString(),
      'ParsedQuery(sql=SELECT * FROM docs__customer WHERE status = ?, params=[Active])',
    );
  });

  test('holds sql and params references', () {
    const q = ParsedQuery(sql: 'SELECT 1', params: []);
    expect(q.sql, 'SELECT 1');
    expect(q.params, isEmpty);
  });
}
