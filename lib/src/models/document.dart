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
