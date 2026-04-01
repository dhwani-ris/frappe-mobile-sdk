import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/exceptions.dart';
import '../services/app_status_service.dart';

/// App guard widget that checks server-side app status on launch.
///
/// Wraps your app and automatically checks `/api/v2/method/mobile_auth.app_status`
/// on mount. Blocks app access if:
/// - `enabled == false` → Shows "App not configured" screen
/// - Package name or version mismatch → Shows force update screen with store redirect
/// - API returns 417/404 → Shows "App not configured" screen
///
/// Usage:
/// ```dart
/// MaterialApp(
///   home: FrappeAppGuard(
///     baseUrl: 'https://your-site.com',
///     child: YourAppHome(),
///   ),
/// )
/// ```
class FrappeAppGuard extends StatefulWidget {
  /// Base URL of Frappe server
  final String baseUrl;

  /// Child widget to show if app status check passes
  final Widget child;

  /// Optional: Override current package identifier used for comparison.
  ///
  /// If not provided, the guard uses `PackageInfo.fromPlatform().packageName`.
  final String? currentPackageName;

  /// Optional: Override current app version used for comparison.
  ///
  /// If not provided, the guard uses `PackageInfo.fromPlatform().version`.
  final String? currentVersion;

  /// Optional: Custom message for "app not configured" screen
  final String? appNotConfiguredMessage;

  /// Optional: Custom title for force update screen
  final String? forceUpdateTitle;

  const FrappeAppGuard({
    super.key,
    required this.baseUrl,
    required this.child,
    this.currentPackageName,
    this.currentVersion,
    this.appNotConfiguredMessage,
    this.forceUpdateTitle,
  });

  @override
  State<FrappeAppGuard> createState() => _FrappeAppGuardState();
}

class _FrappeAppGuardState extends State<FrappeAppGuard> {
  bool _isChecking = true;
  bool _isAppBlocked = false;
  bool _forceUpdateRequired = false;
  bool _maintenanceMode = false;
  String? _errorMessage;
  String? _storeUrl;
  String? _updateTitle;

  @override
  void initState() {
    super.initState();
    _checkAppStatus();
  }

  Future<void> _checkAppStatus() async {
    if (widget.baseUrl.isEmpty) {
      setState(() => _isChecking = false);
      return;
    }

    try {
      final service = AppStatusService(widget.baseUrl);
      final status = await service.fetchAppStatus();
      final info =
          (widget.currentPackageName == null || widget.currentVersion == null)
          ? await PackageInfo.fromPlatform()
          : null;

      if (!status.enabled) {
        if (!mounted) return;
        setState(() {
          _isAppBlocked = true;
          _errorMessage =
              widget.appNotConfiguredMessage ??
              'This app is not configured for mobile access.';
          _isChecking = false;
        });
        return;
      }

      if (status.maintenanceMode) {
        if (!mounted) return;
        setState(() {
          _maintenanceMode = true;
          _errorMessage =
              (status.maintenanceMessage != null &&
                  status.maintenanceMessage!.trim().isNotEmpty)
              ? status.maintenanceMessage
              : 'This app is temporarily down for maintenance. Please try again later.';
          _isChecking = false;
        });
        return;
      }

      final expectedPackage = status.packageName;
      final expectedVersion = status.version;
      final currentPackage = widget.currentPackageName ?? info!.packageName;
      final currentVersion = widget.currentVersion ?? info!.version;

      final packageMismatch =
          expectedPackage != null &&
          expectedPackage.isNotEmpty &&
          expectedPackage != currentPackage;
      final versionMismatch =
          expectedVersion != null &&
          expectedVersion.isNotEmpty &&
          expectedVersion != currentVersion;

      if (packageMismatch || versionMismatch) {
        String? storeUrl = status.storeUrl;
        final pkg = expectedPackage?.isNotEmpty == true
            ? expectedPackage!
            : currentPackage;
        if (storeUrl == null || storeUrl.isEmpty) {
          if (Platform.isAndroid) {
            storeUrl = 'https://play.google.com/store/apps/details?id=$pkg';
          } else if (Platform.isIOS) {
            storeUrl =
                'https://apps.apple.com/us/search?term=$pkg&entity=software';
          }
        }

        if (!mounted) return;
        setState(() {
          _forceUpdateRequired = true;
          _updateTitle =
              widget.forceUpdateTitle ?? status.appTitle ?? 'Update required';
          _storeUrl = storeUrl;
          _isChecking = false;
        });
        return;
      }

      if (!mounted) return;
      setState(() => _isChecking = false);
    } catch (e) {
      // Treat 417 (ValidationException) and 404 as "app not configured"
      if (e is ValidationException ||
          (e is ApiException && (e.statusCode == 417 || e.statusCode == 404))) {
        if (!mounted) return;
        setState(() {
          _isAppBlocked = true;
          _errorMessage =
              widget.appNotConfiguredMessage ??
              'This app is not configured for mobile access.';
          _isChecking = false;
        });
        return;
      }
      // Ignore other errors (network, etc.) to avoid blocking app on transient failures.
      if (!mounted) return;
      setState(() => _isChecking = false);
    }
  }

  Future<void> _openStore() async {
    final url = _storeUrl;
    if (url == null || url.isEmpty) return;
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isChecking) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (_forceUpdateRequired) {
      return Scaffold(
        appBar: AppBar(title: const Text('Update Required')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.system_update, size: 80, color: Colors.blue),
                const SizedBox(height: 24),
                Text(
                  _updateTitle ?? 'Update required',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'A newer version of this app is required. '
                  'Please update from the store to continue.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: _openStore,
                  child: const Text('Open Store'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (_maintenanceMode) {
      return Scaffold(
        appBar: AppBar(title: const Text('Maintenance')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.build, size: 80, color: Colors.orange),
                const SizedBox(height: 24),
                const Text(
                  'Under maintenance',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                Text(
                  _errorMessage ?? 'Please try again later.',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (_isAppBlocked) {
      return Scaffold(
        appBar: AppBar(title: const Text('App Not Available')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.lock, size: 80, color: Colors.red),
                const SizedBox(height: 24),
                const Text(
                  'App not configured',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                Text(
                  _errorMessage ??
                      'This app is not configured. Please contact support.',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      );
    }

    return widget.child;
  }
}
