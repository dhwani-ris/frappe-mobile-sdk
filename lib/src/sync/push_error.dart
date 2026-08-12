import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/outbox_row.dart';
import '../api/utils.dart' show extractErrorMessage;

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

/// A transient server-side contention failure that the request should be
/// retried after a short delay — most commonly MySQL/MariaDB error 1213
/// ("Deadlock found when trying to get lock; try restarting transaction"),
/// which Frappe surfaces as `QueryDeadlockError` (HTTP 500).
///
/// This is raised by the consumer's `send` callback when it recognises a
/// deadlock in the server response, so that [PushEngine]'s attempt loop
/// retries it (with backoff + jitter) instead of letting the raw
/// `ApiException` escape to the terminal `markFailed` path. Deadlocks are
/// inherently transient: a retry against a now-uncontended `tabSeries`
/// row almost always succeeds.
///
/// If every retry is exhausted it maps to [ErrorCode.NETWORK] — the
/// closest "transient, retry later" code the error UI already groups under
/// `retryAll` — rather than `UNKNOWN`, which reads as a hard failure.
class DeadlockError extends PushError {
  @override
  final String message;
  DeadlockError({required this.message});
  @override
  ErrorCode toErrorCode() => ErrorCode.NETWORK;
  @override
  String toString() => 'DeadlockError: $message';
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

  /// Memoised [message]. Computed at most once per instance.
  ///
  /// [message] used to run `jsonDecode` + `extractErrorMessage` on EVERY read,
  /// and it is read repeatedly on error paths (persisted to
  /// `outbox.error_message`, logged, rendered in the Sync Errors list). Both
  /// inputs — [status] and [rawBody] — are final, and Dart `String`s are
  /// immutable, so the result can never legitimately change between reads:
  /// caching is observationally identical to recomputing.
  ///
  /// Every `try`/`catch` lives inside [_buildMessage] precisely so this lazy
  /// initializer can NEVER throw — a throwing `late final` initializer would
  /// leave the field unassigned and re-run on each subsequent read, turning a
  /// malformed body into a repeated failure at every access site.
  late final String _cachedMessage = _buildMessage();

  @override
  String get message => _cachedMessage;

  String _buildMessage() {
    // Surface the server's real validation text (e.g. "…required fields are
    // empty: District, Block…") instead of a bare "status=417". The SDK's
    // extractErrorMessage() unwraps Frappe's `_server_messages`; this value is
    // what markPaused/markFailed persist into outbox.error_message, so the Sync
    // Errors list and the home banner show an actionable reason, not a code.
    try {
      final human = extractErrorMessage(jsonDecode(rawBody));
      if (human.isNotEmpty && human != 'Unknown Error') {
        // Bridge: keep the HTTP status discoverable in the persisted text so
        // hosts still classifying by substring (e.g. `errorMessage.contains
        // ('417')`) keep working while they migrate to the typed contract —
        // `error_code` (the ErrorCode enum name, e.g. 'VALIDATION') or the
        // status here. See toErrorCode() for the code mapping.
        return '$human (HTTP $status)';
      }
    } catch (_) {
      // Malformed/empty body — fall back to the generic label below.
    }
    return 'ServerRejection status=$status';
  }

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
