import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/api/exceptions.dart';
import 'package:frappe_mobile_sdk/src/sync/attachment_error_classifier.dart';

void main() {
  group('terminal — retrying can never succeed', () {
    // A 417 is terminal only when the body NAMES a terminal Frappe exception.
    // `exc_type` is always present on an API-v1 error response
    // (`frappe/utils/response.py` sets it unconditionally), and `RestHelper`
    // hands the whole decoded body to `ValidationException.errors` — so this is
    // a structured check, not a substring guess.
    test('417 naming MaxFileSizeReachedError is terminal', () {
      expect(
        isTerminalAttachmentError(
          ValidationException('File size exceeded the maximum allowed size', {
            'exc_type': 'MaxFileSizeReachedError',
          }),
        ),
        isTrue,
      );
    });

    test('417 naming FileTypeNotAllowed is terminal', () {
      expect(
        isTerminalAttachmentError(
          ValidationException('not allowed', {
            'exc_type': 'FileTypeNotAllowed',
          }),
        ),
        isTrue,
      );
    });

    test('an API-v2 error shape is read too', () {
      // v2 reports `errors: [{type: ...}]` instead of a top-level `exc_type`.
      expect(
        isTerminalAttachmentError(
          ValidationException('not allowed', {
            'errors': [
              {'type': 'FileTypeNotAllowed'},
            ],
          }),
        ),
        isTrue,
      );
    });

    test('HTTP 413 — the real oversized-upload status — is terminal', () {
      // Frappe sets werkzeug's `max_content_length` to the SAME
      // `get_max_file_size()` value (`frappe/app.py:194`), so the HTTP layer
      // rejects an oversized upload with a 413 and an HTML body before
      // `MaxFileSizeReachedError` (417) can ever be raised. Verified against a
      // live v16 bench: a 30 MB upload returned `413 Request Entity Too Large`.
      // The non-JSON body means this arrives as an ApiException, and the 4xx
      // rule below is what makes it terminal — so removing the blanket-417 rule
      // does not weaken the oversized case.
      expect(isTerminalAttachmentError(ApiException('too large', 413)), isTrue);
    });

    test('AuthException 403 (permission denied) is terminal', () {
      expect(
        isTerminalAttachmentError(AuthException('not permitted', 403)),
        isTrue,
      );
    });

    test('a 4xx ApiException is terminal', () {
      expect(
        isTerminalAttachmentError(ApiException('bad request', 400)),
        isTrue,
      );
      expect(isTerminalAttachmentError(ApiException('not found', 404)), isTrue);
    });

    test('MaxFileSizeReachedError is terminal however it is wrapped', () {
      expect(
        isTerminalAttachmentError(
          Exception('frappe.exceptions.MaxFileSizeReachedError: too big'),
        ),
        isTrue,
      );
    });
  });

  group('transient — a later attempt may succeed', () {
    // The inversion this fix is about. 417 is where EVERY `frappe.throw` lands
    // — a storage-quota rule, a custom File hook, any transient server-side
    // business rule — so treating the whole class as terminal contradicted this
    // module's own stated policy ("a wrongly-transient error costs one retry; a
    // wrongly-terminal one strands the user's file with no automatic recovery.
    // Fail toward retrying") and applied that cost to Frappe's broadest error
    // class.
    test('a generic 417 frappe.throw is transient', () {
      expect(
        isTerminalAttachmentError(
          ValidationException('Storage quota exceeded for this site', {
            'exc_type': 'ValidationError',
          }),
        ),
        isFalse,
      );
    });

    test('a 417 with no exc_type at all is transient', () {
      expect(
        isTerminalAttachmentError(ValidationException('something went wrong')),
        isFalse,
      );
    });

    test('NetworkException is transient', () {
      expect(
        isTerminalAttachmentError(NetworkException('Upload failed: socket')),
        isFalse,
      );
    });

    test('AuthException 401 is transient — a token refresh fixes it', () {
      // 401 means the credential expired, not that this file is unacceptable.
      // Rejecting here would strand the attachment behind a re-login.
      expect(isTerminalAttachmentError(AuthException('expired', 401)), isFalse);
    });

    test('5xx is transient', () {
      expect(isTerminalAttachmentError(ApiException('boom', 500)), isFalse);
      expect(
        isTerminalAttachmentError(ApiException('unavailable', 503)),
        isFalse,
      );
    });

    test('429 and 408 are transient despite being 4xx', () {
      expect(
        isTerminalAttachmentError(ApiException('slow down', 429)),
        isFalse,
      );
      expect(isTerminalAttachmentError(ApiException('timeout', 408)), isFalse);
    });

    test('an unrecognised error defaults to transient', () {
      // Fail toward retrying: a wrongly-transient error costs one retry, but a
      // wrongly-terminal one strands the user's file with no auto-recovery.
      expect(
        isTerminalAttachmentError(Exception('something unexpected')),
        isFalse,
      );
    });

    test('an ApiException with no status is transient', () {
      expect(isTerminalAttachmentError(ApiException('no status')), isFalse);
    });
  });
}
