import 'dart:convert';
import 'package:floor/floor.dart';

/// TypeConverter for Map<String, dynamic> to JSON string
class MapTypeConverter extends TypeConverter<Map<String, dynamic>, String> {
  @override
  Map<String, dynamic> decode(String databaseValue) {
    return jsonDecode(databaseValue) as Map<String, dynamic>;
  }

  @override
  String encode(Map<String, dynamic> value) {
    return jsonEncode(value);
  }
}
