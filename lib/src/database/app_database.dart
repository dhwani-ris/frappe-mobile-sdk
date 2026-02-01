import 'dart:async';
import 'package:floor/floor.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'entities/doctype_meta_entity.dart';
import 'entities/document_entity.dart';
import 'entities/link_option_entity.dart';
import 'daos/doctype_meta_dao.dart';
import 'daos/document_dao.dart';
import 'daos/link_option_dao.dart';

part 'app_database.g.dart';

@Database(
  version: 2,
  entities: [DoctypeMetaEntity, DocumentEntity, LinkOptionEntity],
)
abstract class AppDatabase extends FloorDatabase {
  DoctypeMetaDao get doctypeMetaDao;
  DocumentDao get documentDao;
  LinkOptionDao get linkOptionDao;

  /// Get database instance
  static Future<AppDatabase> getInstance() async {
    return await $FloorAppDatabase
        .databaseBuilder('frappe_mobile_sdk.db')
        .addMigrations([
          Migration(1, 2, (database) async {
            // Create link_options table
            await database.execute(
                'CREATE TABLE IF NOT EXISTS `link_options` (`id` INTEGER PRIMARY KEY AUTOINCREMENT, `doctype` TEXT NOT NULL, `name` TEXT NOT NULL, `label` TEXT, `dataJson` TEXT, `lastUpdated` INTEGER NOT NULL)');
            // Create indexes
            await database.execute(
                'CREATE INDEX IF NOT EXISTS `index_link_options_doctype` ON `link_options` (`doctype`)');
            await database.execute(
                'CREATE INDEX IF NOT EXISTS `index_link_options_lastUpdated` ON `link_options` (`lastUpdated`)');
          }),
        ])
        .build();
  }

  /// Clear all data from all tables. Call on logout to wipe local DB.
  static Future<void> clearAllData() async {
    final db = await getInstance();
    await db.doctypeMetaDao.deleteAll();
    await db.documentDao.deleteAll();
    await db.linkOptionDao.deleteAll();
  }
}
