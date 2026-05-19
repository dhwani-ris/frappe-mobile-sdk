// ignore_for_file: constant_identifier_names

enum OutboxOperation { insert, update, submit, cancel, delete }

enum OutboxState { pending, inFlight, done, failed, conflict, blocked }

enum ErrorCode {
  NETWORK,
  TIMEOUT,
  TIMESTAMP_MISMATCH,
  LINK_EXISTS,
  PERMISSION_DENIED,
  VALIDATION,
  MANDATORY,
  UNKNOWN,
}

extension ErrorCodeHelpers on ErrorCode {
  String get wireName => name;
  static ErrorCode? parse(String? raw) {
    if (raw == null) return null;
    for (final c in ErrorCode.values) {
      if (c.name == raw) return c;
    }
    return ErrorCode.UNKNOWN;
  }
}

extension OutboxOperationHelpers on OutboxOperation {
  String get wireName => name.toUpperCase();
  static OutboxOperation parse(String raw) {
    switch (raw.toUpperCase()) {
      case 'INSERT':
        return OutboxOperation.insert;
      case 'UPDATE':
        return OutboxOperation.update;
      case 'SUBMIT':
        return OutboxOperation.submit;
      case 'CANCEL':
        return OutboxOperation.cancel;
      case 'DELETE':
        return OutboxOperation.delete;
    }
    throw ArgumentError.value(raw, 'operation');
  }
}

extension OutboxStateHelpers on OutboxState {
  String get wireName {
    switch (this) {
      case OutboxState.pending:
        return 'pending';
      case OutboxState.inFlight:
        return 'in_flight';
      case OutboxState.done:
        return 'done';
      case OutboxState.failed:
        return 'failed';
      case OutboxState.conflict:
        return 'conflict';
      case OutboxState.blocked:
        return 'blocked';
    }
  }

  static OutboxState parse(String raw) {
    switch (raw) {
      case 'pending':
        return OutboxState.pending;
      case 'in_flight':
        return OutboxState.inFlight;
      case 'done':
        return OutboxState.done;
      case 'failed':
        return OutboxState.failed;
      case 'conflict':
        return OutboxState.conflict;
      case 'blocked':
        return OutboxState.blocked;
    }
    throw ArgumentError.value(raw, 'state');
  }
}

class OutboxRow {
  final int id;
  final String doctype;
  final String mobileUuid;
  final String? serverName;
  final OutboxOperation operation;
  final String? payload;
  final OutboxState state;
  final int retryCount;
  final DateTime? lastAttemptAt;
  final String? errorMessage;
  final ErrorCode? errorCode;
  final DateTime createdAt;

  OutboxRow({
    required this.id,
    required this.doctype,
    required this.mobileUuid,
    this.serverName,
    required this.operation,
    this.payload,
    required this.state,
    required this.retryCount,
    this.lastAttemptAt,
    this.errorMessage,
    this.errorCode,
    required this.createdAt,
  });

  factory OutboxRow.fromMap(Map<String, Object?> row) {
    return OutboxRow(
      id: row['id'] as int,
      doctype: row['doctype'] as String,
      mobileUuid: row['mobile_uuid'] as String,
      serverName: row['server_name'] as String?,
      operation: OutboxOperationHelpers.parse(row['operation'] as String),
      payload: row['payload'] as String?,
      state: OutboxStateHelpers.parse(row['state'] as String),
      retryCount: (row['retry_count'] as int?) ?? 0,
      lastAttemptAt: row['last_attempt_at'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              row['last_attempt_at'] as int,
              isUtc: true,
            ),
      errorMessage: row['error_message'] as String?,
      errorCode: ErrorCodeHelpers.parse(row['error_code'] as String?),
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        row['created_at'] as int,
        isUtc: true,
      ),
    );
  }
}
