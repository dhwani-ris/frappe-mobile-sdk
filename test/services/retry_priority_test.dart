import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/outbox_row.dart';
import 'package:frappe_mobile_sdk/src/services/retry_priority.dart';

OutboxRow row(int id, OutboxState state, ErrorCode? code, {DateTime? at}) =>
    OutboxRow(
      id: id,
      doctype: 'X',
      mobileUuid: '$id',
      operation: OutboxOperation.insert,
      state: state,
      errorCode: code,
      retryCount: 0,
      createdAt: at ?? DateTime.utc(2026, 1, id),
    );

void main() {
  test('orders NETWORK before BLOCKED before CONFLICT...', () {
    final rows = [
      row(1, OutboxState.failed, ErrorCode.PERMISSION_DENIED),
      row(2, OutboxState.failed, ErrorCode.VALIDATION),
      row(3, OutboxState.blocked, null),
      row(4, OutboxState.conflict, ErrorCode.TIMESTAMP_MISMATCH),
      row(5, OutboxState.failed, ErrorCode.NETWORK),
      row(6, OutboxState.failed, ErrorCode.LINK_EXISTS),
    ];
    final ordered = RetryPriority.sort(rows);
    expect(ordered.map((r) => r.id).toList(), [5, 3, 4, 6, 2, 1]);
  });

  test('preserves created_at order within same priority bucket', () {
    final rows = [
      row(2, OutboxState.failed, ErrorCode.NETWORK,
          at: DateTime.utc(2026, 1, 2)),
      row(1, OutboxState.failed, ErrorCode.NETWORK,
          at: DateTime.utc(2026, 1, 1)),
    ];
    final ordered = RetryPriority.sort(rows);
    expect(ordered.map((r) => r.id).toList(), [1, 2]);
  });

  test('TIMEOUT treated same as NETWORK', () {
    final rows = [
      row(1, OutboxState.failed, ErrorCode.PERMISSION_DENIED),
      row(2, OutboxState.failed, ErrorCode.TIMEOUT),
    ];
    final ordered = RetryPriority.sort(rows);
    expect(ordered.first.id, 2);
  });

  test('UNKNOWN / null → last priority', () {
    final rows = [
      row(1, OutboxState.failed, ErrorCode.UNKNOWN),
      row(2, OutboxState.failed, ErrorCode.NETWORK),
    ];
    final ordered = RetryPriority.sort(rows);
    expect(ordered.first.id, 2);
    expect(ordered.last.id, 1);
  });

  test('MANDATORY ordered same as VALIDATION', () {
    final rows = [
      row(1, OutboxState.failed, ErrorCode.PERMISSION_DENIED),
      row(2, OutboxState.failed, ErrorCode.MANDATORY),
    ];
    final ordered = RetryPriority.sort(rows);
    expect(ordered.first.id, 2);
  });
}
