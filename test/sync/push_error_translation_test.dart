// Fix B — `translateFrappeException()` maps the raw HTTP-boundary
// FrappeException hierarchy into the PushError the engine's error matrix
// understands. Without translation every real-world failure (the consumer's
// `client.document.*` calls throw NetworkException / AuthException /
// ValidationException / ApiException straight through) would land in the
// catch-all and be recorded as UNKNOWN.
//
// Proof mapping (plan §Fix B / T-B5): 401 → AUTH, 403 → PERMISSION_DENIED,
// ValidationException / ApiException → ServerRejection, NetworkException →
// NetworkError.
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/api/exceptions.dart';
import 'package:frappe_mobile_sdk/src/models/outbox_row.dart';
import 'package:frappe_mobile_sdk/src/sync/push_error.dart';

void main() {
  group('translateFrappeException', () {
    test('NetworkException → NetworkError (NETWORK, transient)', () {
      final e = translateFrappeException(NetworkException('offline'));
      expect(e, isA<NetworkError>());
      expect(e.toErrorCode(), ErrorCode.NETWORK);
    });

    test('AuthException 401 → AuthError (AUTH, transient)', () {
      final e = translateFrappeException(AuthException('session expired', 401));
      expect(e, isA<AuthError>());
      expect(e.toErrorCode(), ErrorCode.AUTH);
    });

    test('AuthException 403 → ServerRejection (PERMISSION_DENIED)', () {
      final e = translateFrappeException(AuthException('forbidden', 403));
      expect(e, isA<ServerRejection>());
      expect(e.toErrorCode(), ErrorCode.PERMISSION_DENIED);
    });

    test('ValidationException → ServerRejection (VALIDATION)', () {
      final e = translateFrappeException(
        ValidationException('Required', {'name': 'required'}),
      );
      expect(e, isA<ServerRejection>());
      expect(e.toErrorCode(), ErrorCode.VALIDATION);
    });

    test('ApiException 500 → ServerRejection (UNKNOWN → transient budget)', () {
      final e = translateFrappeException(ApiException('boom', 500));
      expect(e, isA<ServerRejection>());
      // No exc_type + non-403/417 status → UNKNOWN. UNKNOWN is deliberately
      // in the transient auto-retry set so real-world field failures recover.
      expect(e.toErrorCode(), ErrorCode.UNKNOWN);
    });

    test('bare FrappeException → ServerRejection (fallback, UNKNOWN)', () {
      final e = translateFrappeException(FrappeException('weird', 599));
      expect(e, isA<ServerRejection>());
      expect(e.toErrorCode(), ErrorCode.UNKNOWN);
    });

    test('ServerRejection derives PERMISSION_DENIED from exc_type', () {
      // Frappe surfaces a structured body; the exc_type wins over the status.
      final e = translateFrappeException(
        ApiException('denied', 500, {'exc_type': 'PermissionError'}),
      );
      expect(e, isA<ServerRejection>());
      expect(e.toErrorCode(), ErrorCode.PERMISSION_DENIED);
    });
  });
}
