/// Entity for mobile auth tokens (stateless login).
///
/// Carries access_token, refresh_token and user info from the
/// mobile_auth.login API. When persisted to the `auth_tokens` table the token
/// fields are written EMPTY: `AuthService` keeps the tokens themselves in
/// secure storage, and the row holds only the non-secret metadata (user, full
/// name, issue time). Rows written by older SDK versions may still carry
/// tokens; `AuthService` moves them to secure storage on first read.
class AuthTokenEntity {
  final int id; // Always 1, single row for current user

  /// Access token for API authentication. Empty in the database row.
  final String accessToken;

  /// Refresh token for obtaining new access tokens. Empty in the database row.
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
