import 'package:flutter/widgets.dart';

import '../../../services/media_resolver.dart';

/// Resolves an attach-field value to a local file path and rebuilds [builder]
/// with the result.
///
/// [builder] receives null while the resolve is in flight and whenever it
/// yields nothing (offline miss, unknown marker, failed fetch), so every caller
/// must have a sensible null branch — typically "fall back to the server URL"
/// or "show a placeholder". Resolution is display-only and never changes the
/// stored value.
///
/// The future is MEMOISED per value. Starting it inside `build` would create a
/// new future on every rebuild, and each completion triggers another rebuild —
/// an infinite loop that re-reads the cache and can re-download forever.
class MediaResolveBuilder extends StatefulWidget {
  final ResolveMediaFn? resolver;
  final String? value;
  final Map<int, String>? pendingPaths;
  final Widget Function(BuildContext context, String? localPath) builder;

  const MediaResolveBuilder({
    super.key,
    required this.resolver,
    required this.value,
    required this.pendingPaths,
    required this.builder,
  });

  @override
  State<MediaResolveBuilder> createState() => _MediaResolveBuilderState();
}

class _MediaResolveBuilderState extends State<MediaResolveBuilder> {
  Future<String?>? _resolved;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(MediaResolveBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value ||
        oldWidget.resolver != widget.resolver) {
      _start();
    }
  }

  void _start() {
    final r = widget.resolver;
    final v = widget.value;
    if (r == null || v == null || v.trim().isEmpty) {
      _resolved = null;
      return;
    }
    _resolved = r(v, pendingPaths: widget.pendingPaths);
  }

  @override
  Widget build(BuildContext context) {
    final future = _resolved;
    // No resolver wired, or nothing to resolve: the caller's null branch is the
    // pre-existing behaviour, so hosts that opt out lose nothing.
    if (future == null) return widget.builder(context, null);
    return FutureBuilder<String?>(
      future: future,
      builder: (context, snapshot) {
        final local = snapshot.data;
        return widget.builder(
          context,
          (local != null && local.isNotEmpty) ? local : null,
        );
      },
    );
  }
}
