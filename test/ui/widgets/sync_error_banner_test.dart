import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/outbox_row.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/sync_error_banner.dart';

OutboxRow _row({
  required OutboxState state,
  ErrorCode? errorCode,
  String? errorMessage,
}) {
  return OutboxRow(
    id: 1,
    doctype: 'X',
    mobileUuid: 'u',
    operation: OutboxOperation.insert,
    state: state,
    retryCount: 0,
    errorCode: errorCode,
    errorMessage: errorMessage,
    createdAt: DateTime.utc(2026, 1, 1),
  );
}

void main() {
  group('humanizeOutboxError', () {
    test('blocked → "Waiting for a related record to sync"', () {
      final t = humanizeOutboxError(_row(state: OutboxState.blocked));
      expect(t.headline, 'Waiting for a related record to sync');
    });

    test('conflict → "This record was changed elsewhere"', () {
      final t = humanizeOutboxError(_row(state: OutboxState.conflict));
      expect(t.headline, 'This record was changed elsewhere');
    });

    test('failed + NETWORK → "Could not reach the server"', () {
      final t = humanizeOutboxError(
        _row(state: OutboxState.failed, errorCode: ErrorCode.NETWORK),
      );
      expect(t.headline, 'Could not reach the server');
    });

    test('failed + VALIDATION → "The server rejected this change"', () {
      final t = humanizeOutboxError(
        _row(state: OutboxState.failed, errorCode: ErrorCode.VALIDATION),
      );
      expect(t.headline, 'The server rejected this change');
    });

    test('failed + PERMISSION_DENIED → permission headline', () {
      final t = humanizeOutboxError(
        _row(state: OutboxState.failed, errorCode: ErrorCode.PERMISSION_DENIED),
      );
      expect(t.headline, "You don't have permission to save this");
    });

    test('failed + TIMESTAMP_MISMATCH → conflict-style headline', () {
      final t = humanizeOutboxError(
        _row(
          state: OutboxState.failed,
          errorCode: ErrorCode.TIMESTAMP_MISMATCH,
        ),
      );
      expect(t.headline, 'This record was changed elsewhere');
    });

    test('failed without errorCode → fallback "Sync failed"', () {
      final t = humanizeOutboxError(_row(state: OutboxState.failed));
      expect(t.headline, 'Sync failed');
    });

    test('detail uses the raw errorMessage when provided', () {
      final t = humanizeOutboxError(
        _row(
          state: OutboxState.blocked,
          errorMessage: 'parent unresolved: house_hold/<uuid>',
        ),
      );
      expect(t.detail, 'parent unresolved: house_hold/<uuid>');
    });

    test('detail falls back to canned copy when errorMessage is empty', () {
      final t = humanizeOutboxError(_row(state: OutboxState.blocked));
      expect(t.detail, isNotEmpty);
      expect(t.detail.contains('depends on'), isTrue);
    });

    test('failed + UNKNOWN: extracts useful first sentence from raw msg', () {
      final t = humanizeOutboxError(
        _row(
          state: OutboxState.failed,
          errorCode: ErrorCode.UNKNOWN,
          errorMessage:
              'ValidationException: Could not find Row #1: Name of Learner: a3102819-2bfe-43bd-a4b7-ae8c2c242a34. '
              'Errors: {exception: frappe.exceptions.LinkValidationError, ...}',
        ),
      );
      expect(
        t.headline,
        'Could not find Row #1: Name of Learner: '
        'a3102819-2bfe-43bd-a4b7-ae8c2c242a34',
      );
      // Detail keeps the full raw payload so a power user can still read
      // the traceback by expanding the banner.
      expect(t.detail.contains('Errors: {exception:'), isTrue);
    });

    test('failed + UNKNOWN with empty msg: falls back to "Sync failed"', () {
      final t = humanizeOutboxError(
        _row(state: OutboxState.failed, errorCode: ErrorCode.UNKNOWN),
      );
      expect(t.headline, 'Sync failed');
    });

    test('LinkValidationError prefix is stripped from extracted line', () {
      final t = humanizeOutboxError(
        _row(
          state: OutboxState.failed,
          errorCode: ErrorCode.UNKNOWN,
          errorMessage: 'LinkValidationError: parent house_hold not found',
        ),
      );
      expect(t.headline, 'parent house_hold not found');
    });

    test('multi-line error message keeps only the first line in headline', () {
      final t = humanizeOutboxError(
        _row(
          state: OutboxState.failed,
          errorMessage:
              'First problem line\nTraceback (most recent call last):\n'
              '  File "x.py", line 1\n    foo()',
        ),
      );
      expect(t.headline, 'First problem line');
    });
  });
}
