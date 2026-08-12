/// Liveness of the stored credential, published by `AuthService` so a host app
/// can react instead of watching every request fail.
enum SessionHealth {
  /// Credentials are good, or no refresh has been attempted yet.
  healthy,

  /// A refresh failed for a reason that may clear by itself — transport
  /// failure, 5xx, or a per-user rate limit. The token is still stored and
  /// will be retried after a cooldown. Hosts should NOT prompt for re-login.
  degraded,

  /// A refresh was DEFINITIVELY rejected. Only a fresh login recovers. Hosts
  /// should prompt. Nothing is wiped by this state.
  ///
  /// The statuses that count differ by leg, so this deliberately does NOT name
  /// one set: `mobile_auth.refresh_token` is `{401, 403, 417}`
  /// (`isDefinitiveRefreshRejection`), while the OAuth `get_token` leg is
  /// `{400, 401, 403}` plus the RFC 6749 error code
  /// (`isDefinitiveOAuthRejection`). Naming only the first set is what let the
  /// OAuth leg's 400 read as transient.
  expired,
}
