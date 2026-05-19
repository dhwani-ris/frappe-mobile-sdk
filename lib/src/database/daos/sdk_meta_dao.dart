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
}
