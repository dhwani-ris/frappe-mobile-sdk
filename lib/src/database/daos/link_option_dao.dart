import 'package:sqflite/sqflite.dart';
import '../entities/link_option_entity.dart';

class LinkOptionDao {
  final Database _database;

  LinkOptionDao(this._database);

  Future<List<LinkOptionEntity>> findByDoctype(String doctype) async {
    final maps = await _database.query(
      'link_options',
      where: 'doctype = ?',
      whereArgs: [doctype],
      orderBy: 'lastUpdated DESC',
    );
    return maps.map((map) => LinkOptionEntity.fromDb(map)).toList();
  }

  Future<List<LinkOptionEntity>> findAll() async {
    final maps = await _database.query('link_options');
    return maps.map((map) => LinkOptionEntity.fromDb(map)).toList();
  }

  Future<void> insertLinkOption(LinkOptionEntity option) async {
    await _database.insert(
      'link_options',
      option.toDb(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> insertLinkOptions(List<LinkOptionEntity> options) async {
    if (options.isEmpty) return;
    final batch = _database.batch();
    for (final option in options) {
      batch.insert(
        'link_options',
        option.toDb(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<void> updateLinkOption(LinkOptionEntity option) async {
    if (option.id == null) {
      throw Exception('Cannot update LinkOptionEntity without id');
    }
    await _database.update(
      'link_options',
      option.toDb(),
      where: 'id = ?',
      whereArgs: [option.id],
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteLinkOption(LinkOptionEntity option) async {
    if (option.id == null) {
      throw Exception('Cannot delete LinkOptionEntity without id');
    }
    await _database.delete(
      'link_options',
      where: 'id = ?',
      whereArgs: [option.id],
    );
  }

  Future<void> deleteByDoctype(String doctype) async {
    await _database.delete(
      'link_options',
      where: 'doctype = ?',
      whereArgs: [doctype],
    );
  }

  Future<void> deleteAll() async {
    await _database.delete('link_options');
  }
}
