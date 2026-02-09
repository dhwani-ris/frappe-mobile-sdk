import 'package:floor/floor.dart';
import '../entities/auth_token_entity.dart';

@dao
abstract class AuthTokenDao {
  @Query('SELECT * FROM auth_tokens WHERE id = 1')
  Future<AuthTokenEntity?> getCurrentToken();

  @insert
  Future<void> insertToken(AuthTokenEntity token);

  @update
  Future<void> updateToken(AuthTokenEntity token);

  @Query('DELETE FROM auth_tokens')
  Future<void> deleteAll();
}
