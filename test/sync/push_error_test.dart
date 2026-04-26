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
    final e = LinkExistsError(linked: {
      'Sales Invoice': ['INV-1', 'INV-2'],
    });
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
    expect(e.toErrorCode(), ErrorCode.UNKNOWN,
        reason: 'BlockedByUpstream is not a failure code per se');
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
}
