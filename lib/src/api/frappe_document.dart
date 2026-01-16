// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// For license information, please see license.txt

class FrappeDocument {
  final Map<String, dynamic> data;

  FrappeDocument(this.data);

  String get name => data['name']?.toString() ?? '';
  String get doctype => data['doctype']?.toString() ?? '';
  String get owner => data['owner']?.toString() ?? '';
  DateTime? get creation =>
      DateTime.tryParse(data['creation']?.toString() ?? '');
  DateTime? get modified =>
      DateTime.tryParse(data['modified']?.toString() ?? '');
  int get docstatus => int.tryParse(data['docstatus']?.toString() ?? '0') ?? 0;

  T? get<T>(String key) {
    return data[key] as T?;
  }

  String getString(String key) {
    return data[key]?.toString() ?? '';
  }

  double getDouble(String key) {
    final val = data[key];
    if (val is num) return val.toDouble();
    if (val is String) return double.tryParse(val) ?? 0.0;
    return 0.0;
  }

  int getInt(String key) {
    final val = data[key];
    if (val is num) return val.toInt();
    if (val is String) return int.tryParse(val) ?? 0;
    return 0;
  }

  bool getBool(String key) {
    final val = data[key];
    if (val is bool) return val;
    if (val is num) return val == 1;
    if (val is String) return val == '1' || val.toLowerCase() == 'true';
    return false;
  }

  Map<String, dynamic> toMap() => data;

  @override
  String toString() => data.toString();
}
