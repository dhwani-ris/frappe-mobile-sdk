import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import '../database/normalize_for_search.dart';
import '../database/schema/system_columns.dart';
import '../models/meta_diff.dart';

class MetaMigration {
  /// Apply a [MetaDiff] inside a single sqflite transaction. If any
  /// statement throws (duplicate column, malformed SQL, etc.), the entire
  /// block rolls back and the table is left in its pre-call shape.
  ///
  /// Per-step progress is emitted via [debugPrint] in debug builds so a
  /// partial failure inside the txn is diagnosable (the transaction itself
  /// is the rollback — no manual undo logic). In release builds
  /// [debugPrint] is a no-op so this has zero production overhead.
  static Future<void> apply(
    Database db,
    MetaDiff diff, {
    required String tableName,
  }) async {
    if (diff.isNoOp) return;
    debugPrint(
      'MetaMigration[$tableName] start: '
      'drop=${diff.indexesToDrop.length}, '
      'add=${diff.addedFields.length}, '
      'isLocal=${diff.addedIsLocalFor.length}, '
      'norm=${diff.addedNormFor.length}',
    );
    await db.transaction((txn) async {
      for (final ix in diff.indexesToDrop) {
        try {
          await txn.execute('DROP INDEX $ix');
          debugPrint('MetaMigration[$tableName] dropped index $ix');
        } on DatabaseException catch (e) {
          // Silently no-op if the index never existed, but log so the
          // distinction between "no-op" and "unexpected SQL error" is
          // visible during a migration failure investigation.
          debugPrint('MetaMigration[$tableName] DROP INDEX $ix skipped — $e');
        }
      }

      for (final af in diff.addedFields) {
        await txn.execute(
          'ALTER TABLE $tableName ADD COLUMN ${af.name} ${af.sqlType}',
        );
        debugPrint(
          'MetaMigration[$tableName] added column ${af.name} ${af.sqlType}',
        );
      }

      for (final ln in diff.addedIsLocalFor) {
        final exists = await _columnExists(txn, tableName, '${ln}__is_local');
        if (!exists) {
          await txn.execute(
            'ALTER TABLE $tableName ADD COLUMN ${linkCompanionColumnDDL(ln)}',
          );
          debugPrint('MetaMigration[$tableName] added ${ln}__is_local');
        }
      }

      for (final nm in diff.addedNormFor) {
        final exists = await _columnExists(txn, tableName, '${nm}__norm');
        if (!exists) {
          await txn.execute(
            'ALTER TABLE $tableName ADD COLUMN ${nm}__norm TEXT',
          );
          debugPrint('MetaMigration[$tableName] added ${nm}__norm');
        }

        // Backfill the __norm column from existing rows in 500-row chunks.
        const chunkSize = 500;
        var offset = 0;
        var backfilled = 0;
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
            backfilled++;
          }
          if (rows.length < chunkSize) break;
          offset += chunkSize;
        }
        if (backfilled > 0) {
          debugPrint(
            'MetaMigration[$tableName] backfilled $backfilled rows for '
            '${nm}__norm',
          );
        }
      }
    });
    debugPrint('MetaMigration[$tableName] done');
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
