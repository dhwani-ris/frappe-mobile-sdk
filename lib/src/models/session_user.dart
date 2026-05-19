/// In-memory snapshot of the logged-in Frappe user. Spec §6.6.
///
/// Populated on login from the response body, persisted to
/// `sdk_meta.session_user_json` so app restarts don't lose context, and
/// cleared atomically on logout. Exposed at
/// [FrappeSDK.instance.sessionUser] (sync read) and `sessionUser$`
/// (Stream for reactive UIs).
///
/// `==`/`hashCode` compare structurally so Provider/Riverpod-style state
/// containers don't re-emit on every login refresh that returns the
/// same user.
class SessionUser {
  final String name;
  final String? fullName;
  final String? userImage;
  final String? language;
  final String? timeZone;
  final List<String> roles;
  final Map<String, List<String>> permissions;
  final Map<String, String> userDefaults;
  final Map<String, dynamic> extras;

  const SessionUser({
    required this.name,
    this.fullName,
    this.userImage,
    this.language,
    this.timeZone,
    required this.roles,
    required this.permissions,
    required this.userDefaults,
    required this.extras,
  });

  Map<String, Object?> toJson() => {
        'name': name,
        if (fullName != null) 'full_name': fullName,
        if (userImage != null) 'user_image': userImage,
        if (language != null) 'language': language,
        if (timeZone != null) 'time_zone': timeZone,
        'roles': roles,
        'permissions':
            permissions.map((k, v) => MapEntry(k, v.toList())),
        'user_defaults': userDefaults,
        'extras': extras,
      };

  factory SessionUser.fromJson(Map<String, dynamic> j) => SessionUser(
        name: j['name'] as String,
        fullName: j['full_name'] as String?,
        userImage: j['user_image'] as String?,
        language: j['language'] as String?,
        timeZone: j['time_zone'] as String?,
        roles: ((j['roles'] as List?) ?? const [])
            .map((e) => e as String)
            .toList(),
        permissions: ((j['permissions'] as Map?) ?? const {}).map(
          (k, v) => MapEntry(
            k as String,
            (v as List).map((e) => e as String).toList(),
          ),
        ),
        userDefaults: ((j['user_defaults'] as Map?) ?? const {})
            .map((k, v) => MapEntry(k as String, v as String)),
        extras: Map<String, dynamic>.from(
          (j['extras'] as Map?) ?? const {},
        ),
      );

  /// Returns true if this user has been granted [op] on [doctype]. Mirrors
  /// the server-side `frappe.has_permission(doctype, op)` semantics
  /// against the snapshot captured at login.
  bool hasPermission(String doctype, String op) {
    return (permissions[doctype] ?? const []).contains(op);
  }

  @override
  bool operator ==(Object other) =>
      other is SessionUser &&
      other.name == name &&
      other.fullName == fullName &&
      other.userImage == userImage &&
      other.language == language &&
      other.timeZone == timeZone &&
      _eqList(other.roles, roles) &&
      _eqMapLists(other.permissions, permissions) &&
      _eqMap(other.userDefaults, userDefaults) &&
      _eqMap(other.extras, extras);

  @override
  int get hashCode => Object.hash(
        name,
        Object.hashAll(roles),
        Object.hashAll(userDefaults.entries),
      );

  static bool _eqList(List a, List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _eqMap(Map a, Map b) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (a[k] != b[k]) return false;
    }
    return true;
  }

  static bool _eqMapLists(
    Map<String, List<String>> a,
    Map<String, List<String>> b,
  ) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (!_eqList(a[k] ?? const [], b[k] ?? const [])) return false;
    }
    return true;
  }
}
