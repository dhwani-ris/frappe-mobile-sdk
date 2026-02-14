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
  /// [permissions] is the full `response['permissions']` object:
  /// `{ "roles": [...], "permissions": { "State": { "read": true, ... } } }`
  /// This method only persists the doctype map; roles are handled by AuthService.
  Future<void> saveFromLoginResponse(Map<String, dynamic>? permissions) async {
    if (permissions == null) return;
    final map = permissions['permissions'] as Map<String, dynamic>?;
    if (map == null) return;
    await _savePermissionMap(map);
  }

  /// Call mobile_auth.permissions API and refresh local cache.
  /// Also returns roles from response so caller can update AuthService if desired.
  /// Returns the raw data payload (contains roles and permissions).
  Future<Map<String, dynamic>?> syncFromApi() async {
    try {
      final result = await _client.rest.get(
        '/api/v2/method/mobile_auth.permissions',
      );
      if (result is! Map<String, dynamic>) return null;
      final data = result['data'] as Map<String, dynamic>? ?? result;
      final map = data['permissions'] as Map<String, dynamic>?;
      if (map != null) {
        await _savePermissionMap(map);
      }
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
