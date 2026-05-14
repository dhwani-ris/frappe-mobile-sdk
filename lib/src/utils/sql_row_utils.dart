/// Small helpers shared by every `fromMap(Map<String, Object?> row)` factory
/// on a model that mirrors a SQLite table. Extracted because the retry /
/// last-attempt / error_message block in `OutboxRow` and `PendingAttachment`
/// was byte-for-byte identical; consolidating here means a change to how
/// retry timestamps are stored (e.g. moving to TEXT) is made in one place
/// across every outbox-shaped model.
library;

/// Reads `retry_count` from a SQLite row, defaulting to 0 when absent or
/// null. Matches the historical inline `(row['retry_count'] as int?) ?? 0`.
int retryCountFrom(Map<String, Object?> row) =>
    (row['retry_count'] as int?) ?? 0;

/// Reads `last_attempt_at` from a SQLite row as a UTC [DateTime], returning
/// null when the column is null. The column is persisted as
/// `millisecondsSinceEpoch` so it reconstructs with `isUtc: true`.
DateTime? lastAttemptAtFrom(Map<String, Object?> row) {
  final raw = row['last_attempt_at'];
  if (raw == null) return null;
  return DateTime.fromMillisecondsSinceEpoch(raw as int, isUtc: true);
}

/// Reads a required UTC [DateTime] millisecond-epoch column from a SQLite
/// row. Used for columns like `created_at` that always exist by schema
/// invariant. Throws if the column is null — that should be impossible
/// for required-by-schema columns.
DateTime utcMillisFrom(Map<String, Object?> row, String key) =>
    DateTime.fromMillisecondsSinceEpoch(row[key] as int, isUtc: true);

/// Resolves an enum value from its `.name` string. Returns null for a
/// null input (preserving callers that treat `parse(null) == null` as
/// "no value supplied"); returns [fallback] for a non-null input that
/// matches no enum value. Used by the `<Enum>Helpers.parse(...)`
/// extensions that previously each rolled their own loop. Type [T] must
/// be the enum type; pass [values] explicitly so the helper stays
/// callable without reflection.
T? parseEnumByName<T extends Enum>(List<T> values, String? raw, {T? fallback}) {
  if (raw == null) return null;
  for (final v in values) {
    if (v.name == raw) return v;
  }
  return fallback;
}
