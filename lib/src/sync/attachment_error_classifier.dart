import '../api/exceptions.dart';
// For the `ErrorCode.isTerminal` extension.
import '../models/outbox_row.dart';
import 'push_error.dart';

/// Frappe exception names that can never succeed on retry.
///
/// Matched first against the error body's `exc_type` (structured), then against
/// the error text as a belt-and-braces check for cases where the typed
/// information has been flattened (e.g. re-thrown as a plain [Exception]).
const List<String> _terminalMarkers = <String>[
  'MaxFileSizeReachedError',
  'FileTypeNotAllowed',
];

/// Frappe's exception class name from a decoded error body, or null when the
/// body carries none.
///
/// Both API generations are read: the SDK calls `/api/method/...` (v1), but the
/// shape is cheap to accept either way.
///
/// * **v1** puts it at the top level as `exc_type`, and does so
///   *unconditionally* — `frappe/utils/response.py` sets
///   `frappe.response["exc_type"] = exc_type.__name__` outside any
///   developer-mode or traceback guard, so it is reliable rather than
///   best-effort.
/// * **v2** reports `errors: [{"type": ...}]` instead.
String? _frappeExcType(Map<String, dynamic>? body) {
  if (body == null) return null;
  final v1 = body['exc_type'];
  if (v1 is String && v1.isNotEmpty) return v1;
  final errors = body['errors'];
  if (errors is List && errors.isNotEmpty) {
    final first = errors.first;
    if (first is Map) {
      final type = first['type'];
      if (type is String && type.isNotEmpty) return type;
    }
  }
  return null;
}

/// 4xx statuses that ARE worth retrying despite the client-error class.
const Set<int> _retryable4xx = <int>{
  408, // Request Timeout
  429, // Too Many Requests
};

/// True when [error] can never succeed on retry, so the attachment must go to
/// `rejected` (blocking the parent push with an actionable reason) rather than
/// `failed` (retried automatically on the next dispatch).
///
/// Defaults to FALSE for anything unrecognised. A wrongly-transient error costs
/// one retry; a wrongly-terminal one strands the user's file with no automatic
/// recovery. Fail toward retrying.
///
/// Grounded in what the upload path actually throws: `RestHelper._handleResponse`
/// raises [ValidationException] on 417, [AuthException] on 401/403,
/// [ApiException] otherwise, and [NetworkException] on transport failure.
bool isTerminalAttachmentError(Object error) {
  // Push-layer type, in case an upload is ever routed through that machinery.
  if (error is ServerRejection) return error.toErrorCode().isTerminal;

  // Transport failure — always worth another attempt.
  if (error is NetworkException) return false;

  // HTTP 417 — where EVERY `frappe.throw` lands, so the status alone says
  // nothing about whether a retry could succeed. A site storage-quota rule, a
  // custom File hook, or any transient server-side business rule arrives here
  // alongside the genuinely terminal cases, and treating the whole class as
  // terminal contradicted this module's own policy above: it strands the user's
  // file with no automatic recovery, applied to Frappe's broadest error class.
  //
  // So classify on the exception Frappe NAMES, not on the status. `exc_type` is
  // always present on a v1 error body and `RestHelper` hands the whole decoded
  // body to `ValidationException.errors`, so this is structured rather than a
  // substring guess; the text check is only a fallback for a body that carried
  // no type at all.
  //
  // This does NOT weaken the oversized-upload case, which never actually
  // reaches 417: Frappe sets werkzeug's `max_content_length` to the same
  // `get_max_file_size()` value (`frappe/app.py:194`), so the HTTP layer
  // rejects with a 413 and an HTML body before `MaxFileSizeReachedError` can be
  // raised. Verified against a live v16 bench — a 30 MB upload returned
  // `413 Request Entity Too Large`. That path lands on the 4xx rule below.
  if (error is ValidationException) {
    final excType = _frappeExcType(error.errors);
    if (excType != null) return _terminalMarkers.contains(excType);
    final text = error.toString();
    return _terminalMarkers.any(text.contains);
  }

  if (error is AuthException) {
    // 403 = this user may not upload here; no retry will change that.
    // 401 = the credential expired. The SDK's refresh machinery handles it and
    // a later attempt succeeds, so rejecting here would strand the file behind
    // a re-login.
    return error.statusCode == 403;
  }

  if (error is FrappeException) {
    final status = error.statusCode;
    if (status == null) return false;
    if (_retryable4xx.contains(status)) return false;
    // Other 4xx are client errors that will repeat identically; 5xx are
    // server-side and may clear.
    return status >= 400 && status < 500;
  }

  final text = error.toString();
  for (final marker in _terminalMarkers) {
    if (text.contains(marker)) return true;
  }
  return false;
}
