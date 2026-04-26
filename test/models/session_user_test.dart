import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/session_user.dart';

void main() {
  test('round-trip to/from JSON', () {
    final u = SessionUser(
      name: 'ankit@example.com',
      fullName: 'Ankit J',
      userImage: null,
      language: 'en',
      timeZone: 'Asia/Kolkata',
      roles: const ['System Manager', 'Customer'],
      permissions: const {
        'Customer': ['read', 'create', 'write'],
      },
      userDefaults: const {'company': 'ACME'},
      extras: const {'custom_key': 42},
    );
    final json = jsonEncode(u.toJson());
    final back =
        SessionUser.fromJson(jsonDecode(json) as Map<String, dynamic>);
    expect(back.name, 'ankit@example.com');
    expect(back.roles, contains('Customer'));
    expect(back.permissions['Customer'], contains('create'));
    expect(back.userDefaults['company'], 'ACME');
    expect(back.extras['custom_key'], 42);
  });

  test('empty user with only name', () {
    final u = SessionUser(
      name: 'bob@b.com',
      roles: const [],
      permissions: const {},
      userDefaults: const {},
      extras: const {},
    );
    final back = SessionUser.fromJson(u.toJson());
    expect(back.name, 'bob@b.com');
  });

  test('hasPermission helper', () {
    final u = SessionUser(
      name: 'x@x.com',
      roles: const [],
      permissions: const {
        'Customer': ['read', 'write'],
      },
      userDefaults: const {},
      extras: const {},
    );
    expect(u.hasPermission('Customer', 'read'), isTrue);
    expect(u.hasPermission('Customer', 'delete'), isFalse);
    expect(u.hasPermission('Sales Order', 'read'), isFalse);
  });

  test('equality + hashCode for riverpod/provider friendly compare', () {
    final a = SessionUser(
      name: 'x',
      roles: const ['A'],
      permissions: const {},
      userDefaults: const {},
      extras: const {},
    );
    final b = SessionUser(
      name: 'x',
      roles: const ['A'],
      permissions: const {},
      userDefaults: const {},
      extras: const {},
    );
    expect(a, b);
    expect(a.hashCode, b.hashCode);
  });
}
