import '../api/client.dart';
import '../database/app_database.dart';
import '../database/entities/doctype_permission_entity.dart';

/// Syncs and caches user permissions from login response or mobile_auth.permissions API.
/// Use [saveFromLoginResponse] after login; use [syncFromApi] on app launch to refresh.
class PermissionService {
  final FrappeClient _client;
  final AppDatabase _database;

  PermissionService(this._client, this._database);

  /// Save permissions from login response.
  /// [permissions] can be:
  /// - List: [ { "doctype": "X", "read": true, "write": false, ... }, ... ]
  /// - Map (legacy): { "roles": [...], "permissions": { "DocType": { "read": true, ... } } }
  Future<void> saveFromLoginResponse(dynamic permissions) async {
    if (permissions == null) return;
    if (permissions is List) {
      final map = <String, Map<String, dynamic>>{};
      for (final item in permissions) {
        if (item is Map<String, dynamic>) {
          final doctype = item['doctype']?.toString();
          if (doctype != null && doctype.isNotEmpty) {
            map[doctype] = item;
          }
        }
      }
      if (map.isNotEmpty) await _savePermissionMap(map);
      return;
    }
    if (permissions is Map<String, dynamic>) {
      final map = permissions['permissions'] as Map<String, dynamic>?;
      if (map != null) await _savePermissionMap(map);
    }
  }

  /// Call mobile_auth.permissions API and refresh local cache.
  /// Accepts permissions as list or map (same as [saveFromLoginResponse]).
  Future<Map<String, dynamic>?> syncFromApi() async {
    try {
      final result = await _client.rest.get(
        '/api/v2/method/mobile_auth.permissions',
      );
      if (result is! Map<String, dynamic>) return null;
      final data = result['data'] as Map<String, dynamic>? ?? result;
      await saveFromLoginResponse(data['permissions']);
      return data;
    } catch (_) {
      return null;
    }
  }

  Future<void> _savePermissionMap(Map<String, dynamic> map) async {
    final entities = <DoctypePermissionEntity>[];
    for (final entry in map.entries) {
      final doctype = entry.key.toString();
      final value = entry.value;
      if (value is Map<String, dynamic>) {
        entities.add(DoctypePermissionEntity.fromApiMap(doctype, value));
      }
    }
    if (entities.isNotEmpty) {
      await _database.doctypePermissionDao.upsertAll(entities);
    }
  }

  Future<DoctypePermissionEntity?> getDoctypePermission(String doctype) async {
    return _database.doctypePermissionDao.findByDoctype(doctype);
  }

  /// Default true if no row (allow); otherwise use stored value.
  Future<bool> canRead(String doctype) async {
    final p = await getDoctypePermission(doctype);
    return p?.read ?? true;
  }

  Future<bool> canCreate(String doctype) async {
    final p = await getDoctypePermission(doctype);
    return p?.create ?? true;
  }

  Future<bool> canWrite(String doctype) async {
    final p = await getDoctypePermission(doctype);
    return p?.write ?? true;
  }

  Future<bool> canDelete(String doctype) async {
    final p = await getDoctypePermission(doctype);
    return p?.delete ?? true;
  }

  Future<bool> canSubmit(String doctype) async {
    final p = await getDoctypePermission(doctype);
    return p?.submit ?? true;
  }
}
