import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../api/exceptions.dart';
import '../models/outbox_row.dart';

/// Common base for every error the push pipeline can raise. Each maps to
/// an [ErrorCode] so the engine can branch on it and write the right
/// state into the outbox row.
abstract class PushError implements Exception {
  String get message;
  ErrorCode toErrorCode();
}

class NetworkError extends PushError {
  @override
  final String message;
  NetworkError({required this.message});
  @override
  ErrorCode toErrorCode() => ErrorCode.NETWORK;
  @override
  String toString() => 'NetworkError: $message';
}

class TimeoutError extends PushError {
  @override
  final String message;
  TimeoutError({required this.message});
  @override
  ErrorCode toErrorCode() => ErrorCode.TIMEOUT;
  @override
  String toString() => 'TimeoutError: $message';
}

/// The server rejected the request with a 401 — the device's session
/// expired mid-push. Session-expiry class: transient and auto-retryable
/// once the token refresh (Fix A) restores the bearer.
class AuthError extends PushError {
  @override
  final String message;
  AuthError({required this.message});
  @override
  ErrorCode toErrorCode() => ErrorCode.AUTH;
  @override
  String toString() => 'AuthError: $message';
}

/// Frappe `check_if_latest` failed — the row has been modified on the
/// server since our snapshot. Engine catches this and triggers a
/// three-way merge + retry-once cycle.
class TimestampMismatchError extends PushError {
  final String? serverModified;
  TimestampMismatchError({this.serverModified});
  @override
  String get message =>
      'Server document was modified '
      '(server_modified=${serverModified ?? "unknown"})';
  @override
  ErrorCode toErrorCode() => ErrorCode.TIMESTAMP_MISMATCH;
}

/// A delete request hit a row that's still linked to others. The engine
/// surfaces this to the UI so the user can choose `Delete all` (cascade)
/// or `Fix manually`.
class LinkExistsError extends PushError {
  /// Doctype → list of server names blocking this delete.
  final Map<String, List<String>> linked;
  LinkExistsError({required this.linked});

  @override
  String get message {
    final parts = linked.entries
        .map((e) => '${e.key}×${e.value.length}')
        .join(', ');
    return 'LinkExists: $parts';
  }

  @override
  ErrorCode toErrorCode() => ErrorCode.LINK_EXISTS;

  String asJsonString() => jsonEncode({'linked': linked});
}

/// Cannot proceed: a Link target hasn't been synced yet, or an attachment
/// upload failed terminally. Engine flips the outbox row to `blocked`.
/// Retries when upstream becomes available (e.g., after the parent's
/// own INSERT lands).
///
/// [reason] is an optional human-readable detail (e.g. the underlying HTTP
/// error from a failed attachment upload) — surfaced in [message] so it
/// reaches `SyncErrorsScreen` without the user having to dig into the
/// `pending_attachments` table.
class BlockedByUpstream extends PushError {
  final String field;
  final String targetDoctype;
  final String targetUuid;
  final String? reason;
  BlockedByUpstream({
    required this.field,
    required this.targetDoctype,
    required this.targetUuid,
    this.reason,
  });
  @override
  String get message {
    final base =
        'BlockedByUpstream field=$field target=$targetDoctype/$targetUuid';
    if (reason == null || reason!.isEmpty) return base;
    return '$base — $reason';
  }

  @override
  ErrorCode toErrorCode() => ErrorCode.UNKNOWN;
}

/// Server already has a row with our `mobile_uuid`. The push engine
/// catches this on INSERT and recovers by fetching the existing doc and
/// writing back as if the original POST had succeeded — Spec §5.7
/// L1 (autoname=field:mobile_uuid) and L2 (consumer's `before_insert`
/// hook) paths both surface here.
///
/// L2's hook raises `frappe.DuplicateEntryError(doctype, existing)` so
/// the consumer's HTTP layer should populate [existingName] when it
/// constructs this error. L1 leaves it null because `name == mobile_uuid`
/// is implicit.
class DuplicateEntryError extends PushError {
  final String? existingName;
  DuplicateEntryError({this.existingName});
  @override
  String get message =>
      'DuplicateEntryError'
      '${existingName != null ? ' existing=$existingName' : ''}';
  @override
  ErrorCode toErrorCode() => ErrorCode.UNKNOWN;
  @override
  String toString() => message;
}

/// Generic server-side rejection. Subtype derived from Frappe's
/// `exc_type` JSON field when present, falling back to HTTP status.
class ServerRejection extends PushError {
  final int status;
  final String rawBody;
  ServerRejection({required this.status, required this.rawBody});

  @override
  String get message => 'ServerRejection status=$status';

  @override
  ErrorCode toErrorCode() {
    Map<String, dynamic>? body;
    try {
      body = jsonDecode(rawBody) as Map<String, dynamic>?;
    } catch (e, st) {
      debugPrint('ServerRejection.toErrorCode: jsonDecode failed — $e\n$st');
      body = null;
    }
    final exc = body?['exc_type'] as String?;
    switch (exc) {
      case 'PermissionError':
        return ErrorCode.PERMISSION_DENIED;
      case 'ValidationError':
        return ErrorCode.VALIDATION;
      case 'MandatoryError':
        return ErrorCode.MANDATORY;
      case 'TimestampMismatchError':
        return ErrorCode.TIMESTAMP_MISMATCH;
      case 'LinkExistsError':
        return ErrorCode.LINK_EXISTS;
    }
    if (status == 403) return ErrorCode.PERMISSION_DENIED;
    if (status == 417) return ErrorCode.VALIDATION;
    return ErrorCode.UNKNOWN;
  }
}

/// Maps a raw [FrappeException] thrown by the HTTP `send` boundary into the
/// [PushError] the engine's `_process` matrix understands. Without this the
/// consumer's `client.document.*` calls throw `NetworkException` /
/// `AuthException` / `ValidationException` / `ApiException` straight through
/// the dispatch loop into the catch-all → every real-world failure would be
/// recorded as `UNKNOWN`.
///
/// - [NetworkException] (offline/timeout, wrapped by RestHelper) → [NetworkError]
///   so the dispatch loop's own `on NetworkError` clause runs its backoff.
/// - [AuthException] 401 → [AuthError] (session-expiry, transient).
/// - [AuthException] 403 → [ServerRejection] (→ PERMISSION_DENIED).
/// - [ValidationException] → [ServerRejection] carrying the error body so
///   `exc_type` derives VALIDATION / MANDATORY.
/// - [ApiException] / other → [ServerRejection] carrying whatever detail is
///   available.
PushError translateFrappeException(FrappeException e) {
  if (e is NetworkException) return NetworkError(message: e.message);
  if (e is AuthException) {
    return e.statusCode == 401
        ? AuthError(message: e.message)
        : ServerRejection(
            status: e.statusCode ?? 403,
            rawBody: jsonEncode({'message': e.message}),
          );
  }
  if (e is ValidationException) {
    return ServerRejection(
      status: 417,
      rawBody: jsonEncode(e.errors ?? {'message': e.message}),
    );
  }
  if (e is ApiException) {
    return ServerRejection(
      status: e.statusCode ?? 0,
      rawBody: _encodeBody(e.details, e.message),
    );
  }
  return ServerRejection(
    status: e.statusCode ?? 0,
    rawBody: jsonEncode({'message': e.message}),
  );
}

/// Best-effort JSON encode of an [ApiException]'s `details` (which may be a
/// decoded Map/List, a raw String, or null). Falls back to a message map on
/// null or a non-encodable value so `ServerRejection.toErrorCode` always has
/// valid JSON to parse.
String _encodeBody(dynamic details, String message) {
  if (details == null) return jsonEncode({'message': message});
  try {
    return jsonEncode(details);
  } catch (_) {
    return jsonEncode({'message': message});
  }
}
