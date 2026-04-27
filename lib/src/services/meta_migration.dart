import 'package:sqflite/sqflite.dart';
import '../database/normalize_for_search.dart';
import '../models/meta_diff.dart';

class MetaMigration {
  /// Apply a [MetaDiff] inside a single sqflite transaction. If any
  /// statement throws (duplicate column, malformed SQL, etc.), the entire
  /// block rolls back and the table is left in its pre-call shape.
  static Future<void> apply(
    Database db,
    MetaDiff diff, {
    required String tableName,
  }) async {
    if (diff.isNoOp) return;
    await db.transaction((txn) async {
      for (final ix in diff.indexesToDrop) {
        try {
          await txn.execute('DROP INDEX $ix');
        } on DatabaseException {
          // Silently no-op if the index never existed.
        }
      }

      for (final af in diff.addedFields) {
        await txn.execute(
          'ALTER TABLE $tableName ADD COLUMN ${af.name} ${af.sqlType}',
        );
      }

      for (final ln in diff.addedIsLocalFor) {
        final exists = await _columnExists(txn, tableName, '${ln}__is_local');
        if (!exists) {
          await txn.execute(
            'ALTER TABLE $tableName ADD COLUMN ${ln}__is_local INTEGER',
          );
        }
      }

      for (final nm in diff.addedNormFor) {
        final exists = await _columnExists(txn, tableName, '${nm}__norm');
        if (!exists) {
          await txn.execute(
            'ALTER TABLE $tableName ADD COLUMN ${nm}__norm TEXT',
          );
        }

        // Backfill the __norm column from existing rows in 500-row chunks.
        const chunkSize = 500;
        var offset = 0;
        while (true) {
          final rows = await txn.query(
            tableName,
            columns: ['mobile_uuid', nm],
            limit: chunkSize,
            offset: offset,
          );
          if (rows.isEmpty) break;
          for (final r in rows) {
            final v = r[nm];
            final norm = v == null ? '' : normalizeForSearch(v.toString());
            await txn.update(
              tableName,
              <String, Object?>{'${nm}__norm': norm},
              where: 'mobile_uuid = ?',
              whereArgs: [r['mobile_uuid']],
            );
          }
          if (rows.length < chunkSize) break;
          offset += chunkSize;
        }
      }
    });
  }

  static Future<bool> _columnExists(
    Transaction txn,
    String tableName,
    String colName,
  ) async {
    final rows = await txn.rawQuery('PRAGMA table_info($tableName)');
    return rows.any((r) => r['name'] == colName);
  }
}
