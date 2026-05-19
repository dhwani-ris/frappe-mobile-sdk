import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/database/daos/auth_token_dao.dart';
import 'package:frappe_mobile_sdk/src/database/entities/auth_token_entity.dart';

AuthTokenEntity _tok({
  int id = 1,
  String accessToken = 'a-1',
  String refreshToken = 'r-1',
  String user = 'alice@example.com',
  String? fullName = 'Alice',
  int createdAt = 1000,
}) => AuthTokenEntity(
  id: id,
  accessToken: accessToken,
  refreshToken: refreshToken,
  user: user,
  fullName: fullName,
  createdAt: createdAt,
);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('getCurrentToken returns null on a fresh database', () async {
    final db = await AppDatabase.inMemoryDatabase();
    final dao = AuthTokenDao(db.rawDatabase);
    expect(await dao.getCurrentToken(), isNull);
    await db.close();
  });

  test('insertToken then getCurrentToken round-trips', () async {
    final db = await AppDatabase.inMemoryDatabase();
    final dao = AuthTokenDao(db.rawDatabase);
    await dao.insertToken(_tok());

    final read = await dao.getCurrentToken();
    expect(read, isNotNull);
    expect(read!.accessToken, 'a-1');
    expect(read.refreshToken, 'r-1');
    expect(read.user, 'alice@example.com');
    expect(read.fullName, 'Alice');
    expect(read.createdAt, 1000);
    await db.close();
  });

  test('insertToken twice replaces the singleton row', () async {
    final db = await AppDatabase.inMemoryDatabase();
    final dao = AuthTokenDao(db.rawDatabase);
    await dao.insertToken(_tok(accessToken: 'a-1'));
    await dao.insertToken(
      _tok(accessToken: 'a-2', refreshToken: 'r-2', createdAt: 2000),
    );

    final read = await dao.getCurrentToken();
    expect(read!.accessToken, 'a-2');
    expect(read.refreshToken, 'r-2');
    expect(read.createdAt, 2000);

    // Only one row total — singleton invariant.
    final rows = await db.rawDatabase.query('auth_tokens');
    expect(rows, hasLength(1));
    await db.close();
  });

  test('updateToken modifies existing row in place', () async {
    final db = await AppDatabase.inMemoryDatabase();
    final dao = AuthTokenDao(db.rawDatabase);
    await dao.insertToken(_tok());
    await dao.updateToken(_tok(accessToken: 'rotated', createdAt: 3000));

    final read = await dao.getCurrentToken();
    expect(read!.accessToken, 'rotated');
    expect(read.createdAt, 3000);
    await db.close();
  });

  test('fullName is optional', () async {
    final db = await AppDatabase.inMemoryDatabase();
    final dao = AuthTokenDao(db.rawDatabase);
    await dao.insertToken(_tok(fullName: null));

    final read = await dao.getCurrentToken();
    expect(read!.fullName, isNull);
    await db.close();
  });

  test('deleteAll clears the table', () async {
    final db = await AppDatabase.inMemoryDatabase();
    final dao = AuthTokenDao(db.rawDatabase);
    await dao.insertToken(_tok());
    await dao.deleteAll();

    expect(await dao.getCurrentToken(), isNull);
    await db.close();
  });
}
