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
      read: (map['read'] as int? ?? 0) == 1,
      write: (map['write'] as int? ?? 0) == 1,
      create: (map['create'] as int? ?? 0) == 1,
      delete: (map['delete'] as int? ?? 0) == 1,
      submit: (map['submit'] as int? ?? 0) == 1,
      cancel: (map['cancel'] as int? ?? 0) == 1,
      amend: (map['amend'] as int? ?? 0) == 1,
    );
  }

  Map<String, dynamic> toDb() {
    return {
      'doctype': doctype,
      'read': read ? 1 : 0,
      'write': write ? 1 : 0,
      'create': create ? 1 : 0,
      'delete': delete ? 1 : 0,
      'submit': submit ? 1 : 0,
      'cancel': cancel ? 1 : 0,
      'amend': amend ? 1 : 0,
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
