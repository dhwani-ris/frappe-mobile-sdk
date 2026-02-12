/// Entity for storing mobile auth tokens (stateless login).
///
/// Stores access_token, refresh_token, user info from mobile_auth.login API.
class AuthTokenEntity {
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

  /// Convert from database map
  factory AuthTokenEntity.fromDb(Map<String, dynamic> map) {
    return AuthTokenEntity(
      id: map['id'] as int,
      accessToken: map['accessToken'] as String,
      refreshToken: map['refreshToken'] as String,
      user: map['user'] as String,
      fullName: map['fullName'] as String?,
      createdAt: map['createdAt'] as int,
    );
  }

  /// Convert to database map
  Map<String, dynamic> toDb() {
    return {
      'id': id,
      'accessToken': accessToken,
      'refreshToken': refreshToken,
      'user': user,
      'fullName': fullName,
      'createdAt': createdAt,
    };
  }
}
