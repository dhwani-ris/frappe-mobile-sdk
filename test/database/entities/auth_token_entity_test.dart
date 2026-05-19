import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/entities/auth_token_entity.dart';

void main() {
  test('fromDb parses all columns', () {
    final e = AuthTokenEntity.fromDb({
      'id': 1,
      'accessToken': 'access-abc',
      'refreshToken': 'refresh-xyz',
      'user': 'test@example.com',
      'fullName': 'Test User',
      'createdAt': 1700000000000,
    });
    expect(e.id, 1);
    expect(e.accessToken, 'access-abc');
    expect(e.refreshToken, 'refresh-xyz');
    expect(e.user, 'test@example.com');
    expect(e.fullName, 'Test User');
    expect(e.createdAt, 1700000000000);
  });

  test('fromDb allows null fullName', () {
    final e = AuthTokenEntity.fromDb({
      'id': 1,
      'accessToken': 'a',
      'refreshToken': 'r',
      'user': 'u@example.com',
      'fullName': null,
      'createdAt': 0,
    });
    expect(e.fullName, isNull);
  });

  test('toDb round-trips all fields', () {
    final e = AuthTokenEntity(
      id: 1,
      accessToken: 'acc',
      refreshToken: 'ref',
      user: 'u@example.com',
      fullName: 'Full Name',
      createdAt: 1700000000000,
    );
    final m = e.toDb();
    expect(m['id'], 1);
    expect(m['accessToken'], 'acc');
    expect(m['refreshToken'], 'ref');
    expect(m['user'], 'u@example.com');
    expect(m['fullName'], 'Full Name');
    expect(m['createdAt'], 1700000000000);
  });

  test('toDb includes null fullName', () {
    final e = AuthTokenEntity(
      accessToken: 'a',
      refreshToken: 'r',
      user: 'u@example.com',
      createdAt: 0,
    );
    expect(e.toDb()['fullName'], isNull);
  });
}
