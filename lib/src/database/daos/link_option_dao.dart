import 'package:floor/floor.dart';
import '../entities/link_option_entity.dart';

@dao
abstract class LinkOptionDao {
  @Query(
    'SELECT * FROM link_options WHERE doctype = :doctype ORDER BY lastUpdated DESC',
  )
  Future<List<LinkOptionEntity>> findByDoctype(String doctype);

  @Query('SELECT * FROM link_options')
  Future<List<LinkOptionEntity>> findAll();

  @insert
  Future<void> insertLinkOption(LinkOptionEntity option);

  @insert
  Future<void> insertLinkOptions(List<LinkOptionEntity> options);

  @update
  Future<void> updateLinkOption(LinkOptionEntity option);

  @delete
  Future<void> deleteLinkOption(LinkOptionEntity option);

  @Query('DELETE FROM link_options WHERE doctype = :doctype')
  Future<void> deleteByDoctype(String doctype);

  @Query('DELETE FROM link_options')
  Future<void> deleteAll();
}
