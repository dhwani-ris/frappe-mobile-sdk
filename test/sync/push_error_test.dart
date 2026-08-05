import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/api/exceptions.dart';
import 'package:frappe_mobile_sdk/src/sync/push_error.dart';
import 'package:frappe_mobile_sdk/src/models/outbox_row.dart';

void main() {
  _serverRejectionMessageTests();
  test('NetworkError maps to ErrorCode.NETWORK', () {
    final e = NetworkError(message: 'timeout');
    expect(e.toErrorCode(), ErrorCode.NETWORK);
  });

  test('TimestampMismatchError carries server_modified for refetch', () {
    final e = TimestampMismatchError(serverModified: '2026-02-01 00:00:00');
    expect(e.toErrorCode(), ErrorCode.TIMESTAMP_MISMATCH);
    expect(e.serverModified, '2026-02-01 00:00:00');
  });

  test('LinkExistsError carries structured linked-docs info', () {
    final e = LinkExistsError(
      linked: {
        'Sales Invoice': ['INV-1', 'INV-2'],
      },
    );
    expect(e.toErrorCode(), ErrorCode.LINK_EXISTS);
    expect(e.linked['Sales Invoice'], ['INV-1', 'INV-2']);
    expect(e.asJsonString(), contains('INV-1'));
  });

  test('BlockedByUpstream records unresolved target', () {
    final e = BlockedByUpstream(
      field: 'customer',
      targetDoctype: 'Customer',
      targetUuid: 'u-1',
    );
    expect(
      e.toErrorCode(),
      ErrorCode.UNKNOWN,
      reason: 'BlockedByUpstream is not a failure code per se',
    );
  });

  test('ServerRejection identifies subtype from Frappe error response', () {
    final perm = ServerRejection(
      status: 403,
      rawBody: '{"exc_type":"PermissionError"}',
    );
    expect(perm.toErrorCode(), ErrorCode.PERMISSION_DENIED);

    final valid = ServerRejection(
      status: 417,
      rawBody: '{"exc_type":"ValidationError"}',
    );
    expect(valid.toErrorCode(), ErrorCode.VALIDATION);

    final mand = ServerRejection(
      status: 417,
      rawBody: '{"exc_type":"MandatoryError"}',
    );
    expect(mand.toErrorCode(), ErrorCode.MANDATORY);

    final unk = ServerRejection(status: 500, rawBody: '{}');
    expect(unk.toErrorCode(), ErrorCode.UNKNOWN);
  });

  test('TimeoutError maps to ErrorCode.TIMEOUT', () {
    final e = TimeoutError(message: 'connection timed out');
    expect(e.toErrorCode(), ErrorCode.TIMEOUT);
  });

  test('NetworkError.toString() includes the message', () {
    final e = NetworkError(message: 'no route');
    expect(e.toString(), 'NetworkError: no route');
  });

  test('TimeoutError.toString() includes the message', () {
    final e = TimeoutError(message: 'took too long');
    expect(e.toString(), 'TimeoutError: took too long');
  });

  test('TimestampMismatchError.message with known serverModified', () {
    final e = TimestampMismatchError(serverModified: '2026-03-01 10:00:00');
    expect(e.message, contains('2026-03-01 10:00:00'));
  });

  test(
    'TimestampMismatchError.message with null serverModified says "unknown"',
    () {
      final e = TimestampMismatchError();
      expect(e.message, contains('unknown'));
    },
  );

  test('LinkExistsError.message formats linked-doc counts', () {
    final e = LinkExistsError(
      linked: {
        'Sales Invoice': ['INV-1', 'INV-2'],
        'Delivery Note': ['DN-1'],
      },
    );
    expect(e.message, contains('Sales Invoice×2'));
    expect(e.message, contains('Delivery Note×1'));
  });

  test('BlockedByUpstream.message without reason omits dash suffix', () {
    final e = BlockedByUpstream(
      field: 'customer',
      targetDoctype: 'Customer',
      targetUuid: 'u-1',
    );
    expect(e.message, startsWith('BlockedByUpstream'));
    expect(e.message, isNot(contains('—')));
  });

  test('BlockedByUpstream.message with reason appends reason after dash', () {
    final e = BlockedByUpstream(
      field: 'attach',
      targetDoctype: 'File',
      targetUuid: '42',
      reason: 'HTTP 503',
    );
    expect(e.message, contains('— HTTP 503'));
  });

  test('DuplicateEntryError.message without existingName', () {
    final e = DuplicateEntryError();
    expect(e.message, 'DuplicateEntryError');
    expect(e.toString(), e.message);
  });

  test('DuplicateEntryError.message with existingName includes it', () {
    final e = DuplicateEntryError(existingName: 'CUST-001');
    expect(e.message, contains('CUST-001'));
    expect(e.toString(), e.message);
    expect(e.toErrorCode(), ErrorCode.UNKNOWN);
  });

  test(
    'ServerRejection.toErrorCode() with non-JSON body falls back to status',
    () {
      final e = ServerRejection(status: 500, rawBody: 'not-json-at-all');
      expect(e.toErrorCode(), ErrorCode.UNKNOWN);
    },
  );

  test(
    'ServerRejection.toErrorCode() maps TimestampMismatchError exc_type',
    () {
      final e = ServerRejection(
        status: 409,
        rawBody: '{"exc_type":"TimestampMismatchError"}',
      );
      expect(e.toErrorCode(), ErrorCode.TIMESTAMP_MISMATCH);
    },
  );

  test('ServerRejection.toErrorCode() maps LinkExistsError exc_type', () {
    final e = ServerRejection(
      status: 417,
      rawBody: '{"exc_type":"LinkExistsError"}',
    );
    expect(e.toErrorCode(), ErrorCode.LINK_EXISTS);
  });

  test('ServerRejection.toErrorCode() falls back to PERMISSION_DENIED on 403 '
      'when exc_type is absent', () {
    final e = ServerRejection(status: 403, rawBody: '{}');
    expect(e.toErrorCode(), ErrorCode.PERMISSION_DENIED);
  });

  test('ServerRejection.toErrorCode() falls back to VALIDATION on 417 '
      'when exc_type is absent', () {
    final e = ServerRejection(status: 417, rawBody: '{}');
    expect(e.toErrorCode(), ErrorCode.VALIDATION);
  });
}

void _serverRejectionMessageTests() {
  group('ServerRejection.message surfaces the server reason (SWF-69164)', () {
    // The outbox stores this string and the Sync screen shows it. It used to be
    // 'ServerRejection status=417' with the body discarded, so a rejection that
    // explained itself perfectly well reached the surveyor as a status code.
    test('extracts the message from _server_messages (double-encoded)', () {
      final body = jsonEncode({
        'exc_type': 'ValidationError',
        '_server_messages': jsonEncode([
          jsonEncode({
            'message':
                "This scheme application's follow-up flow is already "
                'closed (current status: Application Rejected). No further '
                'follow-ups can be added.',
            'title': 'Message',
          }),
        ]),
      });
      final e = ServerRejection(status: 417, rawBody: body);
      expect(e.message, contains('follow-up flow is already closed'));
      expect(e.message, contains('Application Rejected'));
      expect(e.message, contains('status=417'));
      expect(e.message, isNot(startsWith('ServerRejection')));
    });

    test('strips HTML that Frappe routinely includes', () {
      final body = jsonEncode({
        '_server_messages': jsonEncode([
          jsonEncode({'message': 'Missing: <b>Village</b><br>Fix it.'}),
        ]),
      });
      expect(
        ServerRejection(status: 417, rawBody: body).message,
        'Missing: Village Fix it. (status=417)',
      );
    });

    test('falls back to `exception`, trimming the class prefix', () {
      final body = jsonEncode({
        'exception': 'frappe.exceptions.ValidationError: Age must be under 130',
      });
      expect(
        ServerRejection(status: 417, rawBody: body).message,
        'Age must be under 130 (status=417)',
      );
    });

    test('falls back to the bare status when the body has nothing usable', () {
      expect(
        ServerRejection(status: 500, rawBody: 'not json at all').message,
        'ServerRejection status=500',
      );
      expect(
        ServerRejection(status: 403, rawBody: jsonEncode({'x': 1})).message,
        'ServerRejection status=403',
      );
    });

    test('error-code mapping is unchanged', () {
      final body = jsonEncode({'exc_type': 'ValidationError'});
      expect(
        ServerRejection(status: 417, rawBody: body).toErrorCode(),
        ErrorCode.VALIDATION,
      );
      expect(
        ServerRejection(status: 403, rawBody: '{}').toErrorCode(),
        ErrorCode.PERMISSION_DENIED,
      );
    });
  });

  // Frappe's `check_if_latest` raises TimestampMismatchError, a subclass of
  // ValidationError → HTTP 417. RestHelper turns every 417 into a
  // ValidationException, so the translator used to flatten it to a plain
  // ServerRejection. PushEngine._process catches `on TimestampMismatchError`
  // to run its three-way merge + retry-once cycle — with the error flattened,
  // that clause could never fire and the merge path was dead code. Every
  // conflict went straight to markFailed, where a user Retry re-sent the same
  // stale `modified` and failed identically, forever.
  group('translateFrappeException — timestamp mismatch (417)', () {
    // Captured from a REAL rejection on stg.swasti.mform.in (2026-08-05) by
    // PUTing a stale `modified`, rather than hand-written from the reported
    // screenshot. Confirms what actually survives the wire: HTTP 417, an
    // `exc_type` that IS present in the body, and the message shape the regex
    // has to parse. `exc` (a full traceback) is elided; nothing reads it.
    const realMessage =
        'Error: SA-2026-55068 (Scheme Application) has been modified after '
        'you have opened it (2026-07-10 12:08:29.642316, '
        '2026-08-05 11:57:56.983030). Please refresh to get the latest '
        'document.';
    final realBody = <String, dynamic>{
      'exception': 'frappe.exceptions.TimestampMismatchError: $realMessage',
      'exc_type': 'TimestampMismatchError',
      '_server_messages': jsonEncode([
        jsonEncode({
          'message': realMessage,
          'as_table': false,
          'title': 'Message',
          'indicator': 'red',
          'raise_exception': 1,
        }),
      ]),
    };

    test('the real staging 417 payload is recognised', () {
      final err = translateFrappeException(
        ValidationException(realMessage, realBody),
      );
      expect(err, isA<TimestampMismatchError>());
      expect(err.toErrorCode(), ErrorCode.TIMESTAMP_MISMATCH);
      // The DB value — the one a refetch returns. NOT the second stamp, which
      // is the server's clock at rejection.
      expect(
        (err as TimestampMismatchError).serverModified,
        '2026-07-10 12:08:29.642316',
      );
    });

    test('exc_type alone is enough, even with an unparseable message', () {
      final err = translateFrappeException(
        ValidationException('translated to another language', {
          'exc_type': 'TimestampMismatchError',
        }),
      );
      expect(err, isA<TimestampMismatchError>());
      expect((err as TimestampMismatchError).serverModified, isNull);
    });

    test('message-only 417 (no exc_type) is still recognised', () {
      // The production payload: RestHelper's `extractErrorMessage` collapses
      // _server_messages to a bare sentence and exc_type does not survive.
      final err = translateFrappeException(
        ValidationException(
          'SA-2026-3004531 (Scheme Application) has been modified after you '
          'have opened it (2026-08-04 19:33:11.775698, '
          '2026-08-04 19:33:25.048539). Please refresh to get the latest '
          'document.',
        ),
      );
      expect(err, isA<TimestampMismatchError>());
    });

    test('captures the server modified stamp for the refetch', () {
      final err = translateFrappeException(
        ValidationException(
          'X has been modified after you have opened it '
          '(2026-08-04 19:33:11.775698, 2026-08-04 19:33:25.048539). '
          'Please refresh to get the latest document.',
        ),
      );
      // First of the pair is the value actually in the database; the second is
      // the server's clock at rejection (Frappe prints `self.modified` after
      // set_user_and_timestamp has already overwritten it — see
      // frappe/model/document.py:866-871).
      expect(
        (err as TimestampMismatchError).serverModified,
        '2026-08-04 19:33:11.775698',
      );
    });

    test('an ordinary 417 validation error is NOT misclassified', () {
      final err = translateFrappeException(
        ValidationException('Marital Status cannot be "Widowed" for a minor', {
          'exc_type': 'ValidationError',
        }),
      );
      expect(err, isA<ServerRejection>());
      expect(err.toErrorCode(), ErrorCode.VALIDATION);
    });
  });
}
