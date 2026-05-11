import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/sync/push_error.dart';
import 'package:frappe_mobile_sdk/src/models/outbox_row.dart';

void main() {
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
