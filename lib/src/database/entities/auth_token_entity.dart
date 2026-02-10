import 'package:floor/floor.dart';

/// Entity for storing mobile auth tokens (stateless login).
///
/// Stores access_token, refresh_token, user info from mobile_auth.login API.
@Entity(tableName: 'auth_tokens')
class AuthTokenEntity {
  @PrimaryKey()
  final int id; // Always 1, single row for current user

  /// Access token for API authentication
  final String accessToken;

  /// Refresh token for obtaining new access tokens
  final String refreshToken;

  /// User email/username
  final String user;

  /// User's full name
  final String? fullName;

  /// Token created timestamp (milliseconds since epoch)
  final int createdAt;

  AuthTokenEntity({
    this.id = 1,
    required this.accessToken,
    required this.refreshToken,
    required this.user,
    this.fullName,
    required this.createdAt,
  });
}
