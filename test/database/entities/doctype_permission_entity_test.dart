import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/entities/doctype_permission_entity.dart';

void main() {
  test('fromDb maps int flags to bools', () {
    final e = DoctypePermissionEntity.fromDb({
      'doctype': 'Customer',
      'can_read': 1,
      'can_write': 1,
      'can_create': 1,
      'can_delete': 0,
      'can_submit': 0,
      'can_cancel': 0,
      'can_amend': 0,
    });
    expect(e.doctype, 'Customer');
    expect(e.read, isTrue);
    expect(e.write, isTrue);
    expect(e.create, isTrue);
    expect(e.delete, isFalse);
    expect(e.submit, isFalse);
    expect(e.cancel, isFalse);
    expect(e.amend, isFalse);
  });

  test('fromDb defaults all missing flags to false', () {
    final e = DoctypePermissionEntity.fromDb({'doctype': 'Lead'});
    expect(e.read, isFalse);
    expect(e.write, isFalse);
    expect(e.create, isFalse);
    expect(e.delete, isFalse);
  });

  test('toDb encodes bools as int flags', () {
    final e = DoctypePermissionEntity(
      doctype: 'Customer',
      read: true,
      write: true,
      submit: true,
    );
    final m = e.toDb();
    expect(m['can_read'], 1);
    expect(m['can_write'], 1);
    expect(m['can_create'], 0);
    expect(m['can_submit'], 1);
    expect(m['can_cancel'], 0);
    expect(m['can_amend'], 0);
  });

  test('fromApiMap parses bool values', () {
    final e = DoctypePermissionEntity.fromApiMap('Sales Order', {
      'read': true,
      'write': true,
      'create': true,
      'delete': false,
      'submit': true,
      'cancel': false,
      'amend': false,
    });
    expect(e.doctype, 'Sales Order');
    expect(e.read, isTrue);
    expect(e.submit, isTrue);
    expect(e.delete, isFalse);
  });

  test('fromApiMap defaults missing bools to false', () {
    final e = DoctypePermissionEntity.fromApiMap('X', {});
    expect(e.read, isFalse);
    expect(e.write, isFalse);
  });

  test('fromApiMap coerces Frappe int Check flags (1/0)', () {
    // frappe.get_all on DocPerm serialises Check fields as int 1/0; Dart's
    // `1 == true` is false, so without coercion every flag would read false.
    final e = DoctypePermissionEntity.fromApiMap('Activity Logger', {
      'read': 1,
      'write': 1,
      'create': 1,
      'delete': 0,
      'submit': 0,
      'cancel': 0,
      'amend': 0,
    });
    expect(e.read, isTrue);
    expect(e.write, isTrue);
    expect(e.create, isTrue);
    expect(e.delete, isFalse);
    expect(e.submit, isFalse);
  });

  test('fromApiMap coerces string Check flags ("1"/"0")', () {
    final e = DoctypePermissionEntity.fromApiMap('Item', {
      'read': '1',
      'write': '0',
      'create': '1',
    });
    expect(e.read, isTrue);
    expect(e.write, isFalse);
    expect(e.create, isTrue);
    expect(e.delete, isFalse);
  });
}
