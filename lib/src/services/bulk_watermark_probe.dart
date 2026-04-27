/// Result of a single call to the optional `<consumer_app>.get_meta_watermarks`
/// helper endpoint. Includes the `X-Mobile-Essentials-Version` header value
/// when present (used to gate other optimisations the consumer app may
/// advertise) and the doctype/modified rows.
class BulkProbeResult {
  final String? headerVersion;
  final List<Map<String, dynamic>> rows;
  const BulkProbeResult({this.headerVersion, required this.rows});
}

/// Cached detection result.
class BulkProbeDetection {
  final bool available;
  final String? version;
  const BulkProbeDetection({required this.available, this.version});
}

typedef BulkProbeRequester = Future<BulkProbeResult> Function(
  String method,
  List<String> doctypes,
);

/// Detects whether the consumer Frappe app exposes a bulk watermark endpoint.
/// On the first call after login, [detect] issues a tiny request with one
/// doctype and caches the outcome for the session. If absent,
/// [MetaService.refreshWatermarks] falls back to per-doctype GETs.
class BulkWatermarkProbe {
  final String appMethodName;
  final BulkProbeRequester requester;

  BulkProbeDetection? _cached;

  BulkWatermarkProbe({
    required this.appMethodName,
    required this.requester,
  });

  Future<BulkProbeDetection> detect({required List<String> candidates}) async {
    if (_cached != null) return _cached!;
    try {
      final probe = candidates.isEmpty ? ['DocType'] : [candidates.first];
      final result = await requester(appMethodName, probe);
      _cached = BulkProbeDetection(
        available: true,
        version: result.headerVersion,
      );
    } catch (_) {
      _cached = const BulkProbeDetection(available: false);
    }
    return _cached!;
  }

  Future<List<Map<String, dynamic>>> fetchWatermarks(
    List<String> doctypes,
  ) async {
    final result = await requester(appMethodName, doctypes);
    return result.rows;
  }

  void reset() {
    _cached = null;
  }
}
