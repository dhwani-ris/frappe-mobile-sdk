/// Represents a Frappe document
class Document {
  /// Local UUID (primary key)
  final String localId;

  /// DocType name
  final String doctype;

  /// Server document name (null for new documents)
  String? serverId;

  /// Document data as Map
  final Map<String, dynamic> data;

  /// Sync status: dirty | clean | deleted
  final String status;

  /// Last modified timestamp (milliseconds since epoch)
  final int modified;

  Document({
    required this.localId,
    required this.doctype,
    this.serverId,
    required this.data,
    this.status = 'clean',
    required this.modified,
  });

  factory Document.fromJson(Map<String, dynamic> json) {
    return Document(
      localId: json['localId'] as String,
      doctype: json['doctype'] as String,
      serverId: json['serverId'] as String?,
      data: json['data'] as Map<String, dynamic>,
      status: json['status'] as String? ?? 'clean',
      modified: json['modified'] as int,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'localId': localId,
      'doctype': doctype,
      'serverId': serverId,
      'data': data,
      'status': status,
      'modified': modified,
    };
  }

  /// Create a new document
  factory Document.create({
    required String doctype,
    required Map<String, dynamic> data,
    required String localId,
  }) {
    return Document(
      localId: localId,
      doctype: doctype,
      data: data,
      status: 'dirty',
      modified: DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// Create from server document
  factory Document.fromServer({
    required String doctype,
    required String serverId,
    required Map<String, dynamic> data,
    required String localId,
  }) {
    return Document(
      localId: localId,
      doctype: doctype,
      serverId: serverId,
      data: data,
      status: 'clean',
      modified: DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// Build a Document from a [UnifiedResolver.resolve] row.
  ///
  /// The resolver returns rows shaped by the underlying source:
  /// - offline mode → row of `docs__<doctype>` (includes `mobile_uuid`,
  ///   `server_name`, `sync_status`, plus all native columns; no `name` column)
  /// - online mode → row of `frappe.client.get_list` (includes `name`
  ///   and the requested fields; no `mobile_uuid` or `sync_status`)
  ///
  /// `localId` falls back to `name` when `mobile_uuid` is absent (online
  /// mode) so list-tile keys remain stable.
  factory Document.fromResolverRow(String doctype, Map<String, Object?> row) {
    // Online rows use 'name'; offline rows use 'server_name' (the offline
    // table schema has no 'name' column — server_name holds the Frappe ID).
    final name = (row['name'] ?? row['server_name'])?.toString();
    final mobileUuid = row['mobile_uuid']?.toString();
    final syncStatus = (row['sync_status']?.toString()) ?? 'synced';
    final status = switch (syncStatus) {
      'dirty' => 'dirty',
      'sync_error' || 'sync_blocked' => 'sync_error',
      _ => 'clean',
    };
    return Document(
      localId: (mobileUuid != null && mobileUuid.isNotEmpty)
          ? mobileUuid
          : (name ?? ''),
      doctype: doctype,
      serverId: name,
      data: Map<String, dynamic>.from(row),
      status: status,
      modified: _parseModified(row['modified']),
    );
  }

  /// Mark as dirty (needs sync)
  Document markDirty() {
    return Document(
      localId: localId,
      doctype: doctype,
      serverId: serverId,
      data: data,
      status: 'dirty',
      modified: DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// Mark as clean (synced)
  Document markClean() {
    return Document(
      localId: localId,
      doctype: doctype,
      serverId: serverId,
      data: data,
      status: 'clean',
      modified: DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// Mark as deleted
  Document markDeleted() {
    return Document(
      localId: localId,
      doctype: doctype,
      serverId: serverId,
      data: data,
      status: 'deleted',
      modified: DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// Update document data
  Document updateData(Map<String, dynamic> newData) {
    final updatedData = Map<String, dynamic>.from(data);
    updatedData.addAll(newData);
    // Always mark as dirty when data is updated (unless already deleted)
    final newStatus = status == 'deleted' ? 'deleted' : 'dirty';
    return Document(
      localId: localId,
      doctype: doctype,
      serverId: serverId,
      data: updatedData,
      status: newStatus,
      modified: DateTime.now().millisecondsSinceEpoch,
    )..serverId = serverId;
  }

  /// Parses a Frappe `modified` value (ISO string from REST or epoch-ms
  /// int from local) into millis-since-epoch. Falls back to "now" so list
  /// rendering and sort keys never receive null.
  static int _parseModified(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) {
      final parsed = DateTime.tryParse(raw);
      if (parsed != null) return parsed.millisecondsSinceEpoch;
    }
    return DateTime.now().millisecondsSinceEpoch;
  }

  /// Copy with method for easier updates
  Document copyWith({
    String? localId,
    String? doctype,
    String? serverId,
    Map<String, dynamic>? data,
    String? status,
    int? modified,
  }) {
    return Document(
      localId: localId ?? this.localId,
      doctype: doctype ?? this.doctype,
      serverId: serverId ?? this.serverId,
      data: data ?? this.data,
      status: status ?? this.status,
      modified: modified ?? this.modified,
    );
  }
}
