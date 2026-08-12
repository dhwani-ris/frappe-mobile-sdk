import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/services/auth_service.dart';
import 'package:frappe_mobile_sdk/src/services/session_health.dart';

void main() {
  group('session health', () {
    test('a fresh AuthService reports healthy', () {
      expect(AuthService().sessionHealth.value, SessionHealth.healthy);
    });

    test('markSessionRecovered clears an expired session', () {
      final auth = AuthService();
      auth.debugMarkExpired('fa1@example.com');
      expect(auth.sessionHealth.value, SessionHealth.expired);
      expect(auth.expiredSessionEmail, 'fa1@example.com');

      auth.markSessionRecovered();
      expect(auth.sessionHealth.value, SessionHealth.healthy);
      expect(auth.expiredSessionEmail, isNull);
    });
  });

  group('refresh circuit breaker', () {
    test('a dead session never attempts another refresh', () {
      final auth = AuthService();
      auth.debugMarkExpired('fa1@example.com');
      expect(auth.debugRefreshAllowed(), isFalse);
    });

    test('a transient failure blocks retries until the cooldown elapses', () {
      var now = DateTime(2026, 8, 7, 12, 0, 0);
      final auth = AuthService()..clock = () => now;

      auth.debugRecordTransientFailure(rateLimited: false); // 30s
      expect(auth.debugRefreshAllowed(), isFalse);
      expect(auth.sessionHealth.value, SessionHealth.degraded);

      now = now.add(const Duration(seconds: 29));
      expect(auth.debugRefreshAllowed(), isFalse);

      now = now.add(const Duration(seconds: 2));
      expect(auth.debugRefreshAllowed(), isTrue);
    });

    test('backoff escalates 30s -> 2m -> 5m -> 15m and then holds', () {
      var now = DateTime(2026, 8, 7, 12, 0, 0);
      final auth = AuthService()..clock = () => now;
      const expected = [
        Duration(seconds: 30),
        Duration(minutes: 2),
        Duration(minutes: 5),
        Duration(minutes: 15),
        Duration(minutes: 15),
      ];
      for (final d in expected) {
        auth.debugRecordTransientFailure(rateLimited: false);
        now = now.add(d - const Duration(seconds: 1));
        expect(auth.debugRefreshAllowed(), isFalse, reason: 'still within $d');
        now = now.add(const Duration(seconds: 2));
        expect(auth.debugRefreshAllowed(), isTrue, reason: 'past $d');
      }
    });

    test('a 429 jumps straight to the maximum cooldown — the limiter is '
        'per-user, so retrying sooner only extends the lockout', () {
      var now = DateTime(2026, 8, 7, 12, 0, 0);
      final auth = AuthService()..clock = () => now;

      auth.debugRecordTransientFailure(rateLimited: true);
      now = now.add(const Duration(minutes: 14));
      expect(auth.debugRefreshAllowed(), isFalse);
      now = now.add(const Duration(minutes: 2));
      expect(auth.debugRefreshAllowed(), isTrue);
    });

    test('recovery re-arms the refresh path', () {
      final auth = AuthService()..clock = () => DateTime(2026, 8, 7, 12);
      auth.debugRecordTransientFailure(rateLimited: true);
      expect(auth.debugRefreshAllowed(), isFalse);
      auth.markSessionRecovered();
      expect(auth.debugRefreshAllowed(), isTrue);
      expect(auth.sessionHealth.value, SessionHealth.healthy);
    });
  });

  group('a transport failure does not climb the ladder', () {
    // The ladder protects the BACKEND's per-user rate limiter. A request that
    // never reached the server cannot have spent any of that budget, so
    // climbing on transport errors was pure cost: time spent offline ratcheted
    // the gate to 15 minutes, and nothing lowered it when connectivity came
    // back. The user was online again and still could not refresh.
    test('repeated transport failures stay on the 30s rung', () {
      var now = DateTime(2026, 8, 7, 12, 0, 0);
      final auth = AuthService()..clock = () => now;

      for (var i = 0; i < 6; i++) {
        auth.debugRecordTransientFailure(rateLimited: false, transport: true);
      }

      now = now.add(const Duration(seconds: 29));
      expect(auth.debugRefreshAllowed(), isFalse);
      now = now.add(const Duration(seconds: 2));
      expect(
        auth.debugRefreshAllowed(),
        isTrue,
        reason:
            'six offline failures must still clear in ~30s; climbing would '
            'have gated this until 15 minutes after the last one',
      );
    });

    test('a transport failure never SHORTENS a server-imposed cooldown', () {
      var now = DateTime(2026, 8, 7, 12, 0, 0);
      final auth = AuthService()..clock = () => now;

      // Server said 429 -> 15 minutes.
      auth.debugRecordTransientFailure(rateLimited: true);
      // Connectivity then drops. This must NOT hand back an early retry.
      auth.debugRecordTransientFailure(rateLimited: false, transport: true);

      now = now.add(const Duration(minutes: 14));
      expect(
        auth.debugRefreshAllowed(),
        isFalse,
        reason:
            'an offline blip mid-lockout must not let the client back in '
            'early — the limiter keys on the user, not the connection',
      );
      now = now.add(const Duration(minutes: 2));
      expect(auth.debugRefreshAllowed(), isTrue);
    });

    test('a transport failure does not consume a server ladder rung', () {
      var now = DateTime(2026, 8, 7, 12, 0, 0);
      final auth = AuthService()..clock = () => now;

      auth.debugRecordTransientFailure(rateLimited: false, transport: true);
      now = now.add(const Duration(minutes: 1));

      // First SERVER-side failure must still be the first rung (30s), not the
      // second — the offline blip must not have advanced the ladder.
      auth.debugRecordTransientFailure(rateLimited: false);
      now = now.add(const Duration(seconds: 31));
      expect(auth.debugRefreshAllowed(), isTrue);
    });
  });
}
