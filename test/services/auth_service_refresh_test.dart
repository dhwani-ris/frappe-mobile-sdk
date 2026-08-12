import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/api/exceptions.dart';
import 'package:frappe_mobile_sdk/src/services/auth_service.dart';

void main() {
  group('isDefinitiveAuthRejection', () {
    test('HTTP 401/403 are definitive rejections (token must be cleared)', () {
      expect(
        isDefinitiveAuthRejection(AuthException('unauthorized', 401)),
        isTrue,
      );
      expect(
        isDefinitiveAuthRejection(AuthException('forbidden', 403)),
        isTrue,
      );
    });

    test('transport failures are NOT rejections — token is kept so an offline '
        'user stays signed in on cached credentials', () {
      expect(
        isDefinitiveAuthRejection(NetworkException('No internet connection')),
        isFalse,
      );
      expect(
        isDefinitiveAuthRejection(
          NetworkException('Server is not responding. Check your connection.'),
        ),
        isFalse,
      );
    });

    test('a 401/403 carried by ApiException is still definitive', () {
      // RestHelper only builds an AuthException when the error body parses as
      // JSON. A non-JSON body — Frappe behind nginx, a proxy error page, an
      // HTML login redirect — returns early as ApiException(msg, 401). Matching
      // on the subtype missed exactly those, so the dead refresh token was KEPT
      // and the client 401'd -> refreshed -> failed forever with no route to
      // re-login.
      expect(
        isDefinitiveAuthRejection(
          ApiException(
            '<html><body>401 Authorization Required</body></html>',
            401,
          ),
        ),
        isTrue,
      );
      expect(
        isDefinitiveAuthRejection(ApiException('<h1>403 Forbidden</h1>', 403)),
        isTrue,
      );
    });

    test('a FrappeException base instance is classified by status too', () {
      expect(isDefinitiveAuthRejection(FrappeException('nope', 401)), isTrue);
      expect(isDefinitiveAuthRejection(FrappeException('nope', 500)), isFalse);
      expect(isDefinitiveAuthRejection(FrappeException('no status')), isFalse);
    });

    test('a NetworkException carrying a status is NOT treated as transport-'
        'only — status wins', () {
      // Defensive: no SDK site constructs one this way today (all six pass no
      // status), but if one ever did, a 401 means the credential was rejected.
      expect(
        isDefinitiveAuthRejection(NetworkException('gateway said no', 401)),
        isTrue,
      );
    });

    test('validation (417) and non-auth statuses never wipe the token', () {
      expect(
        isDefinitiveAuthRejection(ValidationException('bad payload')),
        isFalse,
      );
      expect(
        isDefinitiveAuthRejection(AuthException('server error', 500)),
        isFalse,
      );
      expect(
        isDefinitiveAuthRejection(ApiException('not found', 404)),
        isFalse,
      );
      expect(isDefinitiveAuthRejection(Exception('unexpected')), isFalse);
    });
  });

  group('isDefinitiveRefreshRejection', () {
    test('401/403 are definitive, as for any credential rejection', () {
      expect(isDefinitiveRefreshRejection(AuthException('nope', 401)), isTrue);
      expect(isDefinitiveRefreshRejection(AuthException('nope', 403)), isTrue);
    });

    test('417 is definitive HERE — the refresh endpoint answers a dead token '
        'with ValidationError "Invalid or expired refresh token", not 401', () {
      expect(
        isDefinitiveRefreshRejection(
          ValidationException('Invalid or expired refresh token'),
        ),
        isTrue,
      );
      expect(isDefinitiveRefreshRejection(FrappeException('x', 417)), isTrue);
    });

    test('429 is NOT definitive — the limiter is per-user, so the token is '
        'still good and must survive the lockout', () {
      expect(
        isDefinitiveRefreshRejection(ApiException('slow down', 429)),
        isFalse,
      );
    });

    test('transport and 5xx are NOT definitive', () {
      expect(
        isDefinitiveRefreshRejection(NetworkException('offline')),
        isFalse,
      );
      expect(isDefinitiveRefreshRejection(ApiException('boom', 500)), isFalse);
      expect(
        isDefinitiveRefreshRejection(FrappeException('no status')),
        isFalse,
      );
    });

    test('the general auth classifier is NOT widened — 417 there would wipe '
        'tokens on any validation error', () {
      expect(
        isDefinitiveAuthRejection(ValidationException('bad payload')),
        isFalse,
      );
    });
  });

  group('isDefinitiveOAuthRejection', () {
    test('400 is definitive HERE — `get_token` forces it for a dead grant', () {
      // The whole reason this predicate exists. oauthlib`s `invalid_grant`
      // arrives in the response body and Frappe sets
      // `http_status_code = 400` on it, so the status set the mobile leg uses
      // ({401, 403, 417}) can never match an expired refresh token here.
      expect(isDefinitiveOAuthRejection(ApiException('nope', 400)), isTrue);
      expect(isDefinitiveOAuthRejection(ApiException('nope', 401)), isTrue);
      expect(isDefinitiveOAuthRejection(ApiException('nope', 403)), isTrue);
    });

    test(
      'an RFC 6749 grant-refusal code is definitive whatever the status',
      () {
        // The 200-with-error shape: no useful status, so the code decides.
        for (final code in const [
          'invalid_grant',
          'invalid_client',
          'unauthorized_client',
          'invalid_scope',
        ]) {
          expect(
            isDefinitiveOAuthRejection(
              ApiException('rejected: $code', null, code),
            ),
            isTrue,
            reason: '$code refuses the grant itself',
          );
        }
      },
    );

    test('invalid_request is NOT definitive — that is an SDK bug, not a dead '
        'credential', () {
      expect(
        isDefinitiveOAuthRejection(
          ApiException('rejected: invalid_request', null, 'invalid_request'),
        ),
        isFalse,
      );
      expect(
        isDefinitiveOAuthRejection(
          ApiException('later', null, 'temporarily_unavailable'),
        ),
        isFalse,
      );
    });

    test('transport, 5xx and 429 are NOT definitive', () {
      expect(isDefinitiveOAuthRejection(NetworkException('offline')), isFalse);
      expect(isDefinitiveOAuthRejection(ApiException('boom', 500)), isFalse);
      expect(isDefinitiveOAuthRejection(ApiException('gateway', 502)), isFalse);
      expect(
        isDefinitiveOAuthRejection(ApiException('slow down', 429)),
        isFalse,
      );
      expect(isDefinitiveOAuthRejection(FrappeException('no status')), isFalse);
    });

    test('417 is NOT adopted here, and 400 is NOT leaked into the shared '
        'predicates', () {
      // `get_token` does not emit 417; and on `mobile_auth.refresh_token` a 400
      // is a malformed request, so widening the shared predicate would wipe a
      // live token over a client-side defect.
      expect(isDefinitiveOAuthRejection(ValidationException('meh')), isFalse);
      expect(
        isDefinitiveRefreshRejection(ApiException('bad body', 400)),
        isFalse,
      );
      expect(isDefinitiveAuthRejection(ApiException('bad body', 400)), isFalse);
    });
  });
}
