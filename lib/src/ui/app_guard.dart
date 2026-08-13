import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/exceptions.dart';
import '../services/app_status_service.dart';
import 'app_guard_version.dart';

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
/// Everything a host app needs to render its own force-update screen.
///
/// Passed to [FrappeAppGuard.forceUpdateBuilder]. [openStore] is the guard's
/// own launcher, so the host does not need `url_launcher` or to know how the
/// store URL was resolved.
class ForceUpdateInfo {
  /// Server-supplied title, or the guard's default.
  final String? title;

  /// Resolved update destination — the server's `store_url` when set,
  /// otherwise a platform store URL derived from the package name.
  final String? storeUrl;

  /// Opens [storeUrl] in an external application. A no-op when there is none.
  final Future<void> Function() openStore;

  const ForceUpdateInfo({
    required this.title,
    required this.storeUrl,
    required this.openStore,
  });
}

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

  /// Optional: render the force-update screen yourself.
  ///
  /// When null the guard renders its own stock screen. Supply this when the
  /// screen needs the host's design system, translated copy, or extra
  /// actions — for example a "sync now" button that drains a pending outbox
  /// before the surveyor leaves for the store.
  final Widget Function(BuildContext context, ForceUpdateInfo info)?
  forceUpdateBuilder;

  /// Optional: change this value to force a fresh status check.
  ///
  /// Compared with `!=` in `didUpdateWidget`. Useful after a login, when the
  /// session — and therefore the answer — may have changed.
  final Object? recheckToken;

  const FrappeAppGuard({
    super.key,
    required this.baseUrl,
    required this.child,
    this.currentPackageName,
    this.currentVersion,
    this.appNotConfiguredMessage,
    this.forceUpdateTitle,
    this.forceUpdateBuilder,
    this.recheckToken,
  });

  @override
  State<FrappeAppGuard> createState() => _FrappeAppGuardState();
}

class _FrappeAppGuardState extends State<FrappeAppGuard>
    with WidgetsBindingObserver {
  bool _isChecking = true;
  bool _isAppBlocked = false;
  bool _forceUpdateRequired = false;
  bool _maintenanceMode = false;
  String? _errorMessage;
  String? _storeUrl;
  String? _updateTitle;

  /// Guards against a status call on every single resume — a surveyor
  /// switching between the camera and the app would otherwise generate a
  /// request per switch.
  static const _recheckThrottle = Duration(minutes: 1);

  DateTime? _lastCheckedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkAppStatus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didUpdateWidget(FrappeAppGuard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.recheckToken != oldWidget.recheckToken) {
      _recheck(force: true);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      _recheck();
    }
  }

  /// Re-runs the check, resetting to the loading state so a newly-blocked
  /// build cannot keep interacting with the app while the call is in flight.
  void _recheck({bool force = false}) {
    final last = _lastCheckedAt;
    if (!force &&
        last != null &&
        DateTime.now().difference(last) < _recheckThrottle) {
      return;
    }
    setState(() {
      _isChecking = true;
      _isAppBlocked = false;
      _forceUpdateRequired = false;
      _maintenanceMode = false;
      _errorMessage = null;
    });
    _checkAppStatus();
  }

  Future<void> _checkAppStatus() async {
    if (widget.baseUrl.isEmpty) {
      setState(() => _isChecking = false);
      return;
    }

    _lastCheckedAt = DateTime.now();

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
      final versionMismatch = appUpdateRequired(
        expected: expectedVersion,
        current: currentVersion,
      );

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
    } catch (e, st) {
      debugPrint('AppGuard: status check failed — $e\n$st');
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
      final builder = widget.forceUpdateBuilder;
      if (builder != null) {
        return builder(
          context,
          ForceUpdateInfo(
            title: _updateTitle,
            storeUrl: _storeUrl,
            openStore: _openStore,
          ),
        );
      }
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
