import 'dart:async';
import 'package:floor/floor.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'entities/doctype_meta_entity.dart';
import 'entities/document_entity.dart';
import 'entities/link_option_entity.dart';
import 'entities/auth_token_entity.dart';
import 'daos/doctype_meta_dao.dart';
import 'daos/document_dao.dart';
import 'daos/link_option_dao.dart';
import 'daos/auth_token_dao.dart';

part 'app_database.g.dart';

@Database(
  version: 1,
  entities: [
    DoctypeMetaEntity,
    DocumentEntity,
    LinkOptionEntity,
    AuthTokenEntity,
  ],
)
abstract class AppDatabase extends FloorDatabase {
  DoctypeMetaDao get doctypeMetaDao;
  DocumentDao get documentDao;
  LinkOptionDao get linkOptionDao;
  AuthTokenDao get authTokenDao;

  /// Get database instance
  static Future<AppDatabase> getInstance() async {
    return await $FloorAppDatabase
        .databaseBuilder('frappe_mobile_sdk.db')
        .build();
  }

  /// Clear all data from all tables. Call on logout to wipe local DB.
  static Future<void> clearAllData() async {
    final db = await getInstance();
    await db.doctypeMetaDao.deleteAll();
    await db.documentDao.deleteAll();
    await db.linkOptionDao.deleteAll();
    await db.authTokenDao.deleteAll();
  }
}
