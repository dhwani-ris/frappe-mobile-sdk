import 'package:sqflite/sqflite.dart';
import '../../models/offline_mode.dart';

/// Single-row read/write helpers for the offline-mode columns on `sdk_meta`.
class SdkMetaDao {
  final Database _db;

  SdkMetaDao(this._db);

  /// Returns the persisted offline mode, or [OfflineMode.fallback] if no
  /// row exists or the column was never set (`set_at IS NULL`).
  Future<OfflineMode> readOfflineMode() async {
    final rows = await _db.rawQuery(
      'SELECT offline_enabled, offline_enabled_set_at FROM sdk_meta WHERE id = 1 LIMIT 1',
    );
    if (rows.isEmpty) return OfflineMode.fallback;
    final row = rows.first;
    if (row['offline_enabled_set_at'] == null) return OfflineMode.fallback;
    final enabled = (row['offline_enabled'] as int? ?? 0) == 1;
    return OfflineMode(enabled: enabled, isPersisted: true);
  }

  /// Persists the offline-mode value with the given epoch-ms timestamp.
  /// UPDATE-then-INSERT-OR-IGNORE on the singleton `id = 1` row: updates
  /// the offline-mode columns when the row exists, inserts it when missing.
  /// Columns not named in the UPDATE's SET clause (`schema_version`,
  /// `bootstrap_done`, `session_user_json`) are preserved.
  ///
  /// IMPORTANT: never use `INSERT OR REPLACE` here. That is `DELETE +
  /// INSERT` in SQLite and would zero out the unrelated columns.
  ///
  /// IMPORTANT: do not use `INSERT … ON CONFLICT … DO UPDATE` either —
  /// that UPSERT syntax requires SQLite ≥ 3.24 (June 2018). Android 8.0
  /// (API 26) and older ship with SQLite < 3.24, so the statement fails
  /// to compile and offline-mode never persists on those devices.
  Future<void> writeOfflineMode({
    required bool enabled,
    required int setAtMs,
  }) async {
    final enabledInt = enabled ? 1 : 0;
    await _db.transaction((txn) async {
      final updated = await txn.rawUpdate(
        'UPDATE sdk_meta '
        'SET offline_enabled = ?, offline_enabled_set_at = ? '
        'WHERE id = 1',
        [enabledInt, setAtMs],
      );
      if (updated == 0) {
        await txn.rawInsert(
          'INSERT OR IGNORE INTO sdk_meta '
          '(id, offline_enabled, offline_enabled_set_at) '
          'VALUES (1, ?, ?)',
          [enabledInt, setAtMs],
        );
      }
    });
  }

  /// Dedicated table holding closure-dependency doctypes that returned a
  /// hard HTTP 403 / PermissionError during a pull. Kept OUT of the
  /// fixed-column singleton `sdk_meta` row so no `ALTER TABLE` + schema-
  /// version bump is needed — created lazily via `CREATE TABLE IF NOT
  /// EXISTS`, which works on every install regardless of the DB version
  /// it was first opened at.
  static const String _skipTable = 'permission_skip_doctypes';

  /// A permission skip is revisited (re-attempted) after this many ms so a
  /// transient 403 (or a later permission grant) can self-heal without a
  /// login/logout. On revisit a 200 removes the row; a fresh 403 re-stamps
  /// it. Kept short-ish so genuinely-restricted framework doctypes are
  /// re-probed at most once a day rather than on every sync.
  static const int permissionSkipTtlMs = 24 * 60 * 60 * 1000;

  /// Creates the skip table in its current 2-column shape, and self-heals a
  /// legacy 1-column table (pre-expiry) by ALTER-adding `denied_at_ms`.
  /// The upgrade migration (`app_database._onUpgrade` v4) drops the legacy
  /// table outright; this ALTER covers any code path that recreated it in
  /// the old shape before the migration ran (e.g. tests / lazy re-create).
  Future<void> _ensureSkipTable() async {
    await _db.execute(
      'CREATE TABLE IF NOT EXISTS $_skipTable '
      '(doctype TEXT PRIMARY KEY NOT NULL, '
      'denied_at_ms INTEGER NOT NULL DEFAULT 0)',
    );
    final cols = await _db.rawQuery('PRAGMA table_info($_skipTable)');
    final hasDeniedAt = cols.any((r) => r['name'] == 'denied_at_ms');
    if (!hasDeniedAt) {
      await _db.execute(
        'ALTER TABLE $_skipTable '
        'ADD COLUMN denied_at_ms INTEGER NOT NULL DEFAULT 0',
      );
    }
  }

  /// Doctypes recorded as permission-denied (HTTP 403) during a prior
  /// closure pull AND still within their revisit window ([permissionSkipTtlMs]
  /// relative to [nowMs]). Expired rows (incl. legacy rows stamped `0`) fall
  /// out so the doctype is re-attempted. The closure-pull filter excludes the
  /// returned set so the app stops re-attempting framework/system doctypes
  /// the surveyor has no read access to on every sync — but only until the
  /// skip expires. Never contains protected doctypes (see storm-breaker in
  /// SyncEngineBuilder: any protected 403 is an auth event that records ZERO
  /// skips).
  Future<Set<String>> readActiveSkippedDoctypes({required int nowMs}) async {
    await _ensureSkipTable();
    final rows = await _db.rawQuery(
      'SELECT doctype FROM $_skipTable WHERE denied_at_ms > ?',
      [nowMs - permissionSkipTtlMs],
    );
    return rows
        .map((r) => r['doctype'] as String?)
        .whereType<String>()
        .toSet();
  }

  /// Records [doctype] in the permission-skip set, stamped [deniedAtMs].
  /// `INSERT OR REPLACE` so a repeat 403 refreshes the stamp (extends the
  /// revisit window). Call ONLY for a genuine HTTP 403 that is NOT part of
  /// an auth event — never for timeouts, SocketException, 5xx, "no such
  /// table", or any 403 on a protected doctype, all of which must remain
  /// retryable.
  Future<void> addSkippedDoctype(
    String doctype, {
    required int deniedAtMs,
  }) async {
    if (doctype.isEmpty) return;
    await _ensureSkipTable();
    await _db.rawInsert(
      'INSERT OR REPLACE INTO $_skipTable (doctype, denied_at_ms) '
      'VALUES (?, ?)',
      [doctype, deniedAtMs],
    );
  }

  /// Removes a single doctype from the skip set. Called on a 200 revisit
  /// (a previously-denied doctype that now pulls successfully) so it
  /// self-heals immediately rather than waiting for the TTL to lapse.
  Future<void> removeSkippedDoctype(String doctype) async {
    if (doctype.isEmpty) return;
    await _ensureSkipTable();
    await _db.rawDelete(
      'DELETE FROM $_skipTable WHERE doctype = ?',
      [doctype],
    );
  }

  /// Clears the permission-skip set. Called on genuine login, on logout,
  /// and on a successful token refresh because read permissions can change
  /// per user / session, so a skip earned under one session must not
  /// suppress a pull under another.
  Future<void> clearSkippedDoctypes() async {
    await _ensureSkipTable();
    await _db.rawDelete('DELETE FROM $_skipTable');
  }
}
