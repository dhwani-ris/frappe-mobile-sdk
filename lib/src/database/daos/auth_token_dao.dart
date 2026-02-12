import 'package:sqflite/sqflite.dart';
import '../entities/auth_token_entity.dart';

class AuthTokenDao {
  final Database _database;

  AuthTokenDao(this._database);

  Future<AuthTokenEntity?> getCurrentToken() async {
    final maps = await _database.query(
      'auth_tokens',
      where: 'id = ?',
      whereArgs: [1],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return AuthTokenEntity.fromDb(maps.first);
  }

  Future<void> insertToken(AuthTokenEntity token) async {
    await _database.insert(
      'auth_tokens',
      token.toDb(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> updateToken(AuthTokenEntity token) async {
    await _database.update(
      'auth_tokens',
      token.toDb(),
      where: 'id = ?',
      whereArgs: [token.id],
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteAll() async {
    await _database.delete('auth_tokens');
  }
}
