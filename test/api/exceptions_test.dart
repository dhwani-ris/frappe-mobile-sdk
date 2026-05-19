import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/api/exceptions.dart';

void main() {
  group('FrappeException', () {
    test('stores message and statusCode', () {
      final e = FrappeException('boom', 500);
      expect(e.message, 'boom');
      expect(e.statusCode, 500);
    });

    test('statusCode is optional', () {
      final e = FrappeException('boom');
      expect(e.statusCode, isNull);
    });

    test('toString formats message + status', () {
      expect(
        FrappeException('boom', 500).toString(),
        'FrappeException: boom (Status: 500)',
      );
      expect(
        FrappeException('boom').toString(),
        'FrappeException: boom (Status: null)',
      );
    });

    test('implements Exception', () {
      expect(FrappeException('x'), isA<Exception>());
    });
  });

  group('AuthException', () {
    test('extends FrappeException', () {
      expect(AuthException('forbidden', 401), isA<FrappeException>());
    });

    test('toString has AuthException prefix', () {
      expect(
        AuthException('forbidden', 401).toString(),
        'AuthException: forbidden (Status: 401)',
      );
    });
  });

  group('ApiException', () {
    test('stores details payload', () {
      final e = ApiException('bad', 400, {'field': 'name'});
      expect(e.message, 'bad');
      expect(e.statusCode, 400);
      expect(e.details, {'field': 'name'});
    });

    test('toString includes details', () {
      final e = ApiException('bad', 400, {'k': 'v'});
      expect(
        e.toString(),
        contains('ApiException: bad (Status: 400) Details: {k: v}'),
      );
    });

    test('details is optional', () {
      final e = ApiException('bad', 400);
      expect(e.details, isNull);
    });
  });

  group('NetworkException', () {
    test('toString omits status by design', () {
      expect(
        NetworkException('offline').toString(),
        'NetworkException: offline',
      );
      expect(
        NetworkException('offline', 503).toString(),
        'NetworkException: offline',
        reason: 'NetworkException.toString does not include status',
      );
    });
  });

  group('ValidationException', () {
    test('forces statusCode to 417', () {
      final e = ValidationException('bad', {
        'name': ['required'],
      });
      expect(e.statusCode, 417);
      expect(e.errors, {
        'name': ['required'],
      });
    });

    test('toString includes errors map', () {
      final e = ValidationException('bad', {
        'name': ['required'],
      });
      expect(
        e.toString(),
        'ValidationException: bad Errors: {name: [required]}',
      );
    });

    test('errors is optional', () {
      final e = ValidationException('bad');
      expect(e.errors, isNull);
    });
  });
}
