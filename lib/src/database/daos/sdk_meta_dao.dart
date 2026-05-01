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
  /// Always upserts onto the singleton `id = 1` row.
  Future<void> writeOfflineMode({
    required bool enabled,
    required int setAtMs,
  }) async {
    await _db.rawUpdate(
      'UPDATE sdk_meta SET offline_enabled = ?, offline_enabled_set_at = ? WHERE id = 1',
      [enabled ? 1 : 0, setAtMs],
    );
  }
}
