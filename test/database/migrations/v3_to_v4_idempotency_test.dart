import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/schema/system_tables.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test(
    'doctypeMetaV4ExtensionsDDL applied twice (with duplicate-column guard) does not throw',
    () async {
      final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      // Set up a v3 doctype_meta with all v3 extensions applied.
      await db.execute('''
        CREATE TABLE doctype_meta (
          doctype TEXT PRIMARY KEY,
          modified TEXT,
          serverModifiedAt TEXT,
          isMobileForm INTEGER NOT NULL DEFAULT 0,
          metaJson TEXT NOT NULL,
          groupName TEXT,
          sortOrder INTEGER
        )
      ''');
      for (final s in doctypeMetaExtensionsDDL()) {
        await db.execute(s);
      }

      Future<void> applyV4WithGuard() async {
        for (final stmt in doctypeMetaV4ExtensionsDDL()) {
          try {
            await db.execute(stmt);
          } on DatabaseException catch (e) {
            if (!e.toString().toLowerCase().contains('duplicate column')) {
              rethrow;
            }
          }
        }
      }

      await applyV4WithGuard();
      await applyV4WithGuard(); // second run must not throw

      final cols = await db.rawQuery('PRAGMA table_info(doctype_meta)');
      final names = cols.map((r) => r['name'] as String).toSet();
      expect(names, contains('is_parent_with_children'));

      await db.close();
    },
  );
}
