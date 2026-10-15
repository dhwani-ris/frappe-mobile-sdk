import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../utils/sdk_log.dart';

/// Describes this app install to the server on every request, via the
/// `X-Client-Info` header.
///
/// Frappe Mobile Control reads this header to keep its device registry
/// (Mobile Device Log) and login history. The wire format is `key=value`
/// pairs joined by `;`:
///
/// ```text
/// app=Field App;ver=2.9.0+72;platform=android;os=...;device=<mobile_uuid>
/// ```
///
/// Keys: `app`, `ver`, `platform`, `os`, `model`, `device`. Empty values are
/// left out. Every value is cleaned by [sanitize]: no `;`, `=` or control
/// characters, printable ASCII only, at most [maxValueLength] characters.
///
/// Nothing here identifies a person. `device` is the SDK's random per-install
/// `mobile_uuid`; it is not a hardware ID and resets when the app is
/// reinstalled.
@immutable
class ClientInfo {
  /// Request header that carries [toHeaderValue].
  static const String headerName = 'X-Client-Info';

  /// The server stores each value in a varchar(140) column and clips to it.
  static const int maxValueLength = 140;

  final String? appName;
  final String? appVersion;
  final String? platform;
  final String? osVersion;
  final String? deviceModel;
  final String? deviceId;

  const ClientInfo({
    this.appName,
    this.appVersion,
    this.platform,
    this.osVersion,
    this.deviceModel,
    this.deviceId,
  });

  /// Builds the info for this install.
  ///
  /// [appName] and [appVersion] override what `package_info_plus` reports.
  /// The default version is pubspec-style `version+buildNumber`, which the
  /// server splits into version and build. [platform] and [osVersion] default
  /// to `dart:io`'s [Platform]. The device model is not collected: that needs
  /// `device_info_plus`, which the SDK does not depend on.
  ///
  /// Never throws: a field that cannot be read is left out.
  static Future<ClientInfo> collect({
    required String? deviceId,
    String? appName,
    String? appVersion,
    String? platform,
    String? osVersion,
    Future<PackageInfo> Function()? packageInfoLoader,
  }) async {
    var name = appName;
    var version = appVersion;
    if (name == null || version == null) {
      try {
        final info = await (packageInfoLoader ?? PackageInfo.fromPlatform)();
        name ??= info.appName.isNotEmpty ? info.appName : info.packageName;
        if (version == null && info.version.isNotEmpty) {
          version = info.buildNumber.isNotEmpty
              ? '${info.version}+${info.buildNumber}'
              : info.version;
        }
      } catch (e) {
        sdkLog('ClientInfo.collect: package info unavailable — $e');
      }
    }
    String? os = osVersion;
    String? plat = platform;
    try {
      plat ??= Platform.operatingSystem;
      os ??= Platform.operatingSystemVersion;
    } catch (_) {
      // dart:io Platform is unavailable (e.g. web). Leave both out.
    }
    return ClientInfo(
      appName: name,
      appVersion: version,
      platform: plat,
      osVersion: os,
      deviceId: deviceId,
    );
  }

  /// Makes [value] safe to place in the header: `;`, `=`, control and
  /// non-ASCII characters become spaces, runs of spaces collapse, and the
  /// result is trimmed and clipped to [maxValueLength]. Returns null when
  /// nothing is left.
  static String? sanitize(String? value) {
    if (value == null) return null;
    final buffer = StringBuffer();
    for (final unit in value.codeUnits) {
      final printable = unit >= 0x20 && unit <= 0x7e;
      final reserved = unit == 0x3b /* ; */ || unit == 0x3d /* = */;
      buffer.writeCharCode(printable && !reserved ? unit : 0x20);
    }
    var cleaned = buffer.toString().replaceAll(RegExp(r' {2,}'), ' ').trim();
    if (cleaned.length > maxValueLength) {
      cleaned = cleaned.substring(0, maxValueLength).trimRight();
    }
    return cleaned.isEmpty ? null : cleaned;
  }

  /// The `X-Client-Info` header value, or null when every field is empty.
  String? toHeaderValue() {
    final pairs = <String>[];
    void add(String key, String? value) {
      final clean = sanitize(value);
      if (clean != null) pairs.add('$key=$clean');
    }

    add('app', appName);
    add('ver', appVersion);
    add('platform', platform);
    add('os', osVersion);
    add('model', deviceModel);
    add('device', deviceId);
    return pairs.isEmpty ? null : pairs.join(';');
  }

  /// `{headerName: toHeaderValue()}`, or an empty map when there is nothing
  /// to send.
  Map<String, String> toHeaders() {
    final value = toHeaderValue();
    return value == null ? const {} : {headerName: value};
  }
}
