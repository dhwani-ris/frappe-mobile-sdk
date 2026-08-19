// Regression guard for the ONE ordering the offline preview depends on.
//
// FormScreen builds the form FIRST and loads the marker→path map second:
// `_loadPendingAttachmentPaths` does a DB round-trip and then setStates the map
// in. So every attach field's first build sees an EMPTY map and a `pending:<id>`
// value it cannot resolve.
//
// `MediaResolveBuilder` memoises its resolve future and `didUpdateWidget`
// restarts only when `value` or `resolver` changes — NOT when `pendingPaths`
// does. Nothing recovers the preview except the synchronously recomputed
// `attachmentDisplaySource` fallback in each field. Remove that fallback and
// an offline-picked image silently never appears, which is precisely the bug
// the pending-marker preview exists to fix — and no other test covers it.
import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/services/media_resolver.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/attach_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/image_field.dart';

/// Mirrors the real resolver's marker branch: a marker resolves ONLY through
/// the map handed in at call time, never over the network.
ResolveMediaFn markerResolver() {
  return (String value, {Map<int, String>? pendingPaths}) async {
    if (value.startsWith('pending:')) {
      final id = int.tryParse(value.substring('pending:'.length));
      return id == null ? null : pendingPaths?[id];
    }
    return null;
  };
}

/// Holds the map in State and swaps it in later, exactly as FormScreen does
/// after its DB round-trip.
class _LateMapHost extends StatefulWidget {
  final Widget Function(Map<int, String>? paths) build;
  const _LateMapHost({super.key, required this.build});
  @override
  State<_LateMapHost> createState() => _LateMapHostState();
}

class _LateMapHostState extends State<_LateMapHost> {
  Map<int, String>? _paths = const {};
  void arrive(Map<int, String> m) => setState(() => _paths = m);
  @override
  Widget build(BuildContext context) => widget.build(_paths);
}

void main() {
  testWidgets('AttachField: a staged file still previews when the marker map '
      'arrives after the first build', (tester) async {
    final hostKey = GlobalKey<_LateMapHostState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FormBuilder(
            child: _LateMapHost(
              key: hostKey,
              build: (paths) => AttachField(
                field: DocField(
                  fieldname: 'doc',
                  fieldtype: 'Attach',
                  label: 'Document',
                ),
                value: 'pending:7',
                mediaResolver: markerResolver(),
                pendingAttachmentPaths: paths,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Before the map lands the marker cannot resolve, and the field says so
    // rather than showing a filename it does not have.
    expect(find.text('Pending upload…'), findsOneWidget);

    hostKey.currentState!.arrive({7: '/outbox/abc/staged.pdf'});
    await tester.pumpAndSettle();

    expect(find.text('staged.pdf'), findsOneWidget);
  });

  testWidgets('ImageField: a staged file still previews when the marker map '
      'arrives after the first build', (tester) async {
    final hostKey = GlobalKey<_LateMapHostState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FormBuilder(
            child: _LateMapHost(
              key: hostKey,
              build: (paths) => ImageField(
                field: DocField(
                  fieldname: 'pic',
                  fieldtype: 'Attach Image',
                  label: 'Photo',
                ),
                value: 'pending:7',
                mediaResolver: markerResolver(),
                pendingAttachmentPaths: paths,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    hostKey.currentState!.arrive({7: '/outbox/abc/staged.jpg'});
    await tester.pumpAndSettle();

    // The staged path must reach an Image.file — that IS the preview.
    final fileImagePaths = tester
        .widgetList<Image>(find.byType(Image))
        .where((w) => w.image is FileImage)
        .map((w) => (w.image as FileImage).file.path)
        .toList();
    expect(fileImagePaths, contains('/outbox/abc/staged.jpg'));
  });
}
