import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/outbox_row.dart';

void main() {
  group('OutboxOperationHelpers', () {
    test('wireName returns upper-case', () {
      expect(OutboxOperation.insert.wireName, 'INSERT');
      expect(OutboxOperation.update.wireName, 'UPDATE');
      expect(OutboxOperation.submit.wireName, 'SUBMIT');
      expect(OutboxOperation.cancel.wireName, 'CANCEL');
      expect(OutboxOperation.delete.wireName, 'DELETE');
    });

    test('parse handles SUBMIT and CANCEL', () {
      expect(OutboxOperationHelpers.parse('SUBMIT'), OutboxOperation.submit);
      expect(OutboxOperationHelpers.parse('CANCEL'), OutboxOperation.cancel);
    });

    test('parse is case-insensitive', () {
      expect(OutboxOperationHelpers.parse('insert'), OutboxOperation.insert);
      expect(OutboxOperationHelpers.parse('Delete'), OutboxOperation.delete);
    });

    test('parse unknown value throws ArgumentError', () {
      expect(() => OutboxOperationHelpers.parse('NOOP'), throwsArgumentError);
    });
  });

  group('OutboxStateHelpers', () {
    test('wireName for inFlight returns "in_flight"', () {
      expect(OutboxState.inFlight.wireName, 'in_flight');
    });

    test('wireName for all other states returns lower-case name', () {
      expect(OutboxState.pending.wireName, 'pending');
      expect(OutboxState.done.wireName, 'done');
      expect(OutboxState.failed.wireName, 'failed');
      expect(OutboxState.conflict.wireName, 'conflict');
      expect(OutboxState.blocked.wireName, 'blocked');
    });

    test('parse round-trips all wire names', () {
      for (final s in OutboxState.values) {
        expect(OutboxStateHelpers.parse(s.wireName), s);
      }
    });

    test('parse unknown value throws ArgumentError', () {
      expect(() => OutboxStateHelpers.parse('unknown'), throwsArgumentError);
    });
  });

  group('ErrorCodeHelpers', () {
    test('wireName equals enum name', () {
      expect(ErrorCode.NETWORK.wireName, 'NETWORK');
      expect(ErrorCode.TIMEOUT.wireName, 'TIMEOUT');
      expect(ErrorCode.TIMESTAMP_MISMATCH.wireName, 'TIMESTAMP_MISMATCH');
    });

    test('parse null returns null', () {
      expect(ErrorCodeHelpers.parse(null), isNull);
    });

    test('parse valid name round-trips', () {
      expect(ErrorCodeHelpers.parse('VALIDATION'), ErrorCode.VALIDATION);
      expect(ErrorCodeHelpers.parse('MANDATORY'), ErrorCode.MANDATORY);
    });

    test('parse unknown string returns UNKNOWN', () {
      expect(ErrorCodeHelpers.parse('FOOBAR'), ErrorCode.UNKNOWN);
    });
  });

  group('OutboxRow.fromMap', () {
    test('parses full row with lastAttemptAt and errorCode', () {
      final row = <String, Object?>{
        'id': 42,
        'doctype': 'Customer',
        'mobile_uuid': 'uuid-1',
        'server_name': 'CUST-1',
        'operation': 'UPDATE',
        'payload': '{}',
        'state': 'failed',
        'retry_count': 3,
        'last_attempt_at': 1700000000000,
        'error_message': 'oops',
        'error_code': 'NETWORK',
        'created_at': 1699000000000,
      };
      final r = OutboxRow.fromMap(row);
      expect(r.id, 42);
      expect(r.doctype, 'Customer');
      expect(r.mobileUuid, 'uuid-1');
      expect(r.serverName, 'CUST-1');
      expect(r.operation, OutboxOperation.update);
      expect(r.state, OutboxState.failed);
      expect(r.retryCount, 3);
      expect(r.lastAttemptAt, isNotNull);
      expect(r.errorMessage, 'oops');
      expect(r.errorCode, ErrorCode.NETWORK);
    });

    test('parses row without optional fields (nulls)', () {
      final row = <String, Object?>{
        'id': 1,
        'doctype': 'Customer',
        'mobile_uuid': 'uuid-2',
        'server_name': null,
        'operation': 'INSERT',
        'payload': null,
        'state': 'pending',
        'retry_count': null,
        'last_attempt_at': null,
        'error_message': null,
        'error_code': null,
        'created_at': 1699000000000,
      };
      final r = OutboxRow.fromMap(row);
      expect(r.serverName, isNull);
      expect(r.payload, isNull);
      expect(r.lastAttemptAt, isNull);
      expect(r.errorCode, isNull);
      expect(r.retryCount, 0);
    });
  });
}
