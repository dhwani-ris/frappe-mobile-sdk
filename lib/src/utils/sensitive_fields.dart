// Shared denylist for request-body fields that must never reach a debug log
// or a captured-for-diagnostics exception field in cleartext.
//
// `RestHelper` stamps the outgoing request body onto both the debug
// [ApiTracer] trace and onto the `requestBody` field of any `FrappeException`
// it throws (so the push-engine error-log collector can rebuild the exact
// request — see `error_capture.dart`). That second path is NOT gated by
// `kDebugMode`: a caller that surfaces `error.requestBody` in a release-mode
// crash report or support log would otherwise leak a live credential.
const Set<String> sensitiveBodyFieldNames = <String>{
  'pwd',
  'password',
  'otp',
  'access_token',
  'refresh_token',
  'api_key',
  'api_secret',
  'client_secret',
  'code_verifier',
  'secret',
};

/// Returns a shallow copy of [body] with any key in [sensitiveBodyFieldNames]
/// masked as `'[REDACTED]'`. Keys are matched case-insensitively. A non-`Map`
/// body (or `null`) is returned unchanged — there is no key to redact.
///
/// Used wherever a request body is captured for logging/diagnostics rather
/// than sent over the wire; the original, unredacted body must still be used
/// for the actual HTTP request.
dynamic redactSensitiveFields(dynamic body) {
  if (body is! Map) return body;
  return body.map((key, value) {
    final isSensitive = sensitiveBodyFieldNames.contains(
      key.toString().toLowerCase(),
    );
    return MapEntry(key, isSensitive ? '[REDACTED]' : value);
  });
}
