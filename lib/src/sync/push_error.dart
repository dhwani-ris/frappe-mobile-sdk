import 'dart:convert';

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
    final parts =
        linked.entries.map((e) => '${e.key}×${e.value.length}').join(', ');
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
class BlockedByUpstream extends PushError {
  final String field;
  final String targetDoctype;
  final String targetUuid;
  BlockedByUpstream({
    required this.field,
    required this.targetDoctype,
    required this.targetUuid,
  });
  @override
  String get message =>
      'BlockedByUpstream field=$field target=$targetDoctype/$targetUuid';
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
    } catch (_) {
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
