// Complements sync_error_banner_test.dart by exercising the message-parsing
// branches: prefix stripping, ". Errors:" / traceback trailer cutoff, raw vs
// canned-fallback detail choice, and the lifecycle states (pending/in_flight/done).
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/outbox_row.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/sync_error_banner.dart';

OutboxRow _row({
  required OutboxState state,
  ErrorCode? errorCode,
  String? errorMessage,
}) => OutboxRow(
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

void main() {
  group('first-line extraction', () {
    test('strips "ValidationException: " prefix', () {
      final t = humanizeOutboxError(
        _row(
          state: OutboxState.failed,
          errorCode: ErrorCode.VALIDATION,
          errorMessage: 'ValidationException: Email is required',
        ),
      );
      expect(t.headline, 'Email is required');
    });

    test('strips "frappe.exceptions.LinkValidationError: " prefix', () {
      final t = humanizeOutboxError(
        _row(
          state: OutboxState.failed,
          errorCode: ErrorCode.LINK_EXISTS,
          errorMessage:
              'frappe.exceptions.LinkValidationError: Could not find Bank',
        ),
      );
      expect(t.headline, 'Could not find Bank');
    });

    test('truncates at ". Errors:" trailer', () {
      final t = humanizeOutboxError(
        _row(
          state: OutboxState.failed,
          errorCode: ErrorCode.VALIDATION,
          errorMessage:
              'ValidationException: Bad row. Errors: {exception: noise}',
        ),
      );
      expect(t.headline, 'Bad row');
    });

    test('truncates at "\\nTraceback" trailer', () {
      final t = humanizeOutboxError(
        _row(
          state: OutboxState.failed,
          errorCode: ErrorCode.UNKNOWN,
          errorMessage:
              'Exception: Something failed\nTraceback (most recent...',
        ),
      );
      expect(t.headline, 'Something failed');
    });

    test('takes only the first line of multi-line messages', () {
      final t = humanizeOutboxError(
        _row(
          state: OutboxState.failed,
          errorCode: ErrorCode.VALIDATION,
          errorMessage: 'ValidationException: first\nsecond\nthird',
        ),
      );
      expect(t.headline, 'first');
    });

    test('strips trailing period from headline', () {
      final t = humanizeOutboxError(
        _row(
          state: OutboxState.failed,
          errorCode: ErrorCode.VALIDATION,
          errorMessage: 'ValidationException: Bad data.',
        ),
      );
      expect(t.headline, 'Bad data');
    });
  });

  group('detail fallback', () {
    test('empty errorMessage uses canned detail for blocked state', () {
      final t = humanizeOutboxError(_row(state: OutboxState.blocked));
      expect(t.detail, contains('not reached the server'));
    });

    test('non-empty errorMessage is used as detail verbatim', () {
      const raw = 'ValidationException: Bad. Errors: {trail: a lot of noise}';
      final t = humanizeOutboxError(
        _row(
          state: OutboxState.failed,
          errorCode: ErrorCode.VALIDATION,
          errorMessage: raw,
        ),
      );
      // The full raw string is preserved as the expanded detail.
      expect(t.detail, raw);
    });

    test('failed + TIMEOUT empty message uses NETWORK canned detail', () {
      final t = humanizeOutboxError(
        _row(state: OutboxState.failed, errorCode: ErrorCode.TIMEOUT),
      );
      expect(t.detail, contains('connect long enough'));
    });

    test('failed + UNKNOWN empty message uses generic fallback', () {
      final t = humanizeOutboxError(
        _row(state: OutboxState.failed, errorCode: ErrorCode.UNKNOWN),
      );
      expect(t.headline, 'Sync failed');
      expect(t.detail, contains('unspecified reason'));
    });

    test('failed with null errorCode uses generic fallback', () {
      final t = humanizeOutboxError(_row(state: OutboxState.failed));
      expect(t.headline, 'Sync failed');
    });
  });

  group('non-failed lifecycle states map to "Sync in progress"', () {
    test('pending', () {
      final t = humanizeOutboxError(_row(state: OutboxState.pending));
      expect(t.headline, 'Sync in progress');
    });

    test('inFlight', () {
      final t = humanizeOutboxError(_row(state: OutboxState.inFlight));
      expect(t.headline, 'Sync in progress');
    });

    test('done', () {
      final t = humanizeOutboxError(_row(state: OutboxState.done));
      expect(t.headline, 'Sync in progress');
    });
  });

  test('blocked + non-empty raw uses the server line as headline', () {
    final t = humanizeOutboxError(
      _row(
        state: OutboxState.blocked,
        errorMessage: 'Dependency CUST-1 not yet pushed',
      ),
    );
    expect(t.headline, 'Dependency CUST-1 not yet pushed');
  });

  test('conflict + non-empty raw uses the server line', () {
    final t = humanizeOutboxError(
      _row(
        state: OutboxState.conflict,
        errorMessage: 'TimestampMismatchError: modified mismatch',
      ),
    );
    expect(t.headline, 'modified mismatch');
  });
}
