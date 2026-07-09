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

  Future<void> _ensureSkipTable() async {
    await _db.execute(
      'CREATE TABLE IF NOT EXISTS $_skipTable '
      '(doctype TEXT PRIMARY KEY NOT NULL)',
    );
  }

  /// Doctypes recorded as permission-denied (HTTP 403) during a prior
  /// closure pull. The closure-pull filter excludes these so the app
  /// stops re-attempting framework/system doctypes the surveyor has no
  /// read access to on every sync. Only ever contains doctypes that
  /// genuinely returned 403 — never mobile-form entry points or readable
  /// masters (those return 200 and so never land here).
  Future<Set<String>> readSkippedDoctypes() async {
    await _ensureSkipTable();
    final rows = await _db.rawQuery('SELECT doctype FROM $_skipTable');
    return rows
        .map((r) => r['doctype'] as String?)
        .whereType<String>()
        .toSet();
  }

  /// Records [doctype] in the permission-skip set. Idempotent
  /// (`INSERT OR IGNORE`). Call ONLY for a genuine HTTP 403 —
  /// never for timeouts, SocketException, 5xx, or "no such table",
  /// which must remain retryable.
  Future<void> addSkippedDoctype(String doctype) async {
    if (doctype.isEmpty) return;
    await _ensureSkipTable();
    await _db.rawInsert(
      'INSERT OR IGNORE INTO $_skipTable (doctype) VALUES (?)',
      [doctype],
    );
  }

  /// Clears the permission-skip set. Called on genuine login and on
  /// logout because read permissions can change per user / session, so a
  /// skip earned under one session must not suppress a pull under another.
  Future<void> clearSkippedDoctypes() async {
    await _ensureSkipTable();
    await _db.rawDelete('DELETE FROM $_skipTable');
  }
}
