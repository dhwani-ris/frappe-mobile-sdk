import 'dart:io';

import 'package:sqflite/sqflite.dart';

typedef OnCreateFn = Future<void> Function(Database db);

/// Deletes the SQLite database file (and its `-wal` / `-shm` siblings)
/// then reopens an empty DB and invokes [onCreate] to rebuild the
/// schema. Spec §7.5.
///
/// File-level delete is atomic at the OS layer, so a half-wiped state
/// is impossible. Caller is responsible for closing any open handles
/// to [dbPath] BEFORE invoking [wipe] — sqflite's writers must release
/// their locks first or the delete will silently fail on Windows.
class AtomicWipe {
  static Future<void> wipe({
    required String dbPath,
    required OnCreateFn onCreate,
  }) async {
    for (final suffix in const ['', '-wal', '-shm']) {
      final file = File('$dbPath$suffix');
      try {
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {
        // best-effort: -wal / -shm may already be gone, or the OS may
        // hold a transient lock. Continue rather than abort the wipe.
      }
    }
    final db = await databaseFactory.openDatabase(dbPath);
    await onCreate(db);
    await db.close();
  }
}
