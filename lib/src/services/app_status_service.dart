import '../api/rest_helper.dart';

/// Result of `/api/v2/method/mobile_auth.app_status`.
class AppStatus {
  final bool enabled;
  final String? packageName;
  final String? appTitle;
  final String? version;
  final String? storeUrl;
  final bool maintenanceMode;
  final String? maintenanceMessage;

  const AppStatus({
    required this.enabled,
    this.packageName,
    this.appTitle,
    this.version,
    this.storeUrl,
    this.maintenanceMode = false,
    this.maintenanceMessage,
  });

  factory AppStatus.fromJson(Map<String, dynamic> json) {
    return AppStatus(
      enabled: json['enabled'] == true,
      packageName: json['package_name'] as String?,
      appTitle: json['app_title'] as String?,
      version: json['version'] as String?,
      storeUrl: json['store_url'] as String?,
      maintenanceMode: json['maintenance_mode'] == true,
      maintenanceMessage: json['maintenance_message'] as String?,
    );
  }
}

/// Service for checking server-side app configuration and version.
class AppStatusService {
  final RestHelper _rest;

  AppStatusService(String baseUrl) : _rest = RestHelper(baseUrl);

  Future<AppStatus> fetchAppStatus() async {
    final result =
        await _rest.get('/api/v2/method/mobile_auth.app_status') ?? {};

    if (result is Map<String, dynamic>) {
      final data = result['data'];
      if (data is Map<String, dynamic>) {
        return AppStatus.fromJson(data);
      }
      return AppStatus.fromJson(result);
    }

    return const AppStatus(enabled: true);
  }
}
