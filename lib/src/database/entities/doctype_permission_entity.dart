/// Entity for storing per-doctype permissions (from login or mobile_auth.permissions).
class DoctypePermissionEntity {
  final String doctype;
  final bool read;
  final bool write;
  final bool create;
  final bool delete;
  final bool submit;
  final bool cancel;
  final bool amend;

  DoctypePermissionEntity({
    required this.doctype,
    this.read = false,
    this.write = false,
    this.create = false,
    this.delete = false,
    this.submit = false,
    this.cancel = false,
    this.amend = false,
  });

  factory DoctypePermissionEntity.fromDb(Map<String, dynamic> map) {
    return DoctypePermissionEntity(
      doctype: map['doctype'] as String,
      read: (map['can_read'] as int? ?? 0) == 1,
      write: (map['can_write'] as int? ?? 0) == 1,
      create: (map['can_create'] as int? ?? 0) == 1,
      delete: (map['can_delete'] as int? ?? 0) == 1,
      submit: (map['can_submit'] as int? ?? 0) == 1,
      cancel: (map['can_cancel'] as int? ?? 0) == 1,
      amend: (map['can_amend'] as int? ?? 0) == 1,
    );
  }

  Map<String, dynamic> toDb() {
    return {
      'doctype': doctype,
      'can_read': read ? 1 : 0,
      'can_write': write ? 1 : 0,
      'can_create': create ? 1 : 0,
      'can_delete': delete ? 1 : 0,
      'can_submit': submit ? 1 : 0,
      'can_cancel': cancel ? 1 : 0,
      'can_amend': amend ? 1 : 0,
    };
  }

  /// From API map e.g. { "read": true, "write": true, ... }
  static DoctypePermissionEntity fromApiMap(
    String doctype,
    Map<String, dynamic> map,
  ) {
    return DoctypePermissionEntity(
      doctype: doctype,
      read: map['read'] == true,
      write: map['write'] == true,
      create: map['create'] == true,
      delete: map['delete'] == true,
      submit: map['submit'] == true,
      cancel: map['cancel'] == true,
      amend: map['amend'] == true,
    );
  }
}
