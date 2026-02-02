import 'package:json_annotation/json_annotation.dart';

part 'app_config.g.dart';

/// Application configuration for Frappe Mobile SDK
///
/// Defines base URL and list of Doctypes to support offline
@JsonSerializable()
class AppConfig {
  /// Frappe server base URL
  final String baseUrl;

  /// List of Doctype names to support offline
  final List<String> doctypes;

  AppConfig({required this.baseUrl, required this.doctypes});

  factory AppConfig.fromJson(Map<String, dynamic> json) =>
      _$AppConfigFromJson(json);

  Map<String, dynamic> toJson() => _$AppConfigToJson(this);

  /// Create from JSON file
  static AppConfig fromJsonFile(Map<String, dynamic> json) {
    return AppConfig(
      baseUrl: json['base_url'] as String? ?? '',
      doctypes:
          (json['doctypes'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
    );
  }
}
