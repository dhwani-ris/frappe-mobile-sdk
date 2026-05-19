import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/entities/link_option_entity.dart';

void main() {
  test('fromDb parses all columns', () {
    final e = LinkOptionEntity.fromDb({
      'id': 5,
      'doctype': 'Customer',
      'name': 'CUST-1',
      'label': 'ACME Corp',
      'dataJson': '{"city":"Delhi"}',
      'lastUpdated': 1700000000000,
    });
    expect(e.id, 5);
    expect(e.doctype, 'Customer');
    expect(e.name, 'CUST-1');
    expect(e.label, 'ACME Corp');
    expect(e.dataJson, '{"city":"Delhi"}');
    expect(e.lastUpdated, 1700000000000);
  });

  test('fromDb allows null id, label and dataJson', () {
    final e = LinkOptionEntity.fromDb({
      'id': null,
      'doctype': 'Lead',
      'name': 'LD-1',
      'label': null,
      'dataJson': null,
      'lastUpdated': 0,
    });
    expect(e.id, isNull);
    expect(e.label, isNull);
    expect(e.dataJson, isNull);
  });

  test('toDb round-trips all fields when id is set', () {
    final e = LinkOptionEntity(
      id: 7,
      doctype: 'Customer',
      name: 'CUST-2',
      label: 'Beta',
      dataJson: '{}',
      lastUpdated: 1000,
    );
    final m = e.toDb();
    expect(m['id'], 7);
    expect(m['doctype'], 'Customer');
    expect(m['name'], 'CUST-2');
    expect(m['label'], 'Beta');
    expect(m['dataJson'], '{}');
    expect(m['lastUpdated'], 1000);
  });

  test('toDb omits id key when id is null', () {
    final e = LinkOptionEntity(
      doctype: 'Customer',
      name: 'CUST-3',
      lastUpdated: 0,
    );
    expect(e.toDb().containsKey('id'), isFalse);
  });
}
