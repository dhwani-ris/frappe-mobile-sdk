import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/services/media_resolver.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/attach_field.dart';

/// The widget depends on the [ResolveMediaFn] function, not on [MediaResolver],
/// so these tests need no database and no filesystem. That matters: widget
/// tests run in a fake-async zone where real sqflite / dart:io futures never
/// complete, so `pumpAndSettle` would hang forever on the real resolver.
/// MediaResolver's own behaviour is covered in test/services/media_resolver_test.dart.
void main() {
  final docField = DocField(
    fieldname: 'doc',
    fieldtype: 'Attach',
    label: 'Document',
  );

  late List<String> resolveCalls;

  setUp(() => resolveCalls = <String>[]);

  ResolveMediaFn resolverReturning(String? path) {
    return (String value, {Map<int, String>? pendingPaths}) async {
      resolveCalls.add(value);
      if (path == null) return null;
      // Mirror the real resolver: a marker resolves through the staging map.
      if (value.startsWith('pending:')) {
        final id = int.tryParse(value.substring('pending:'.length));
        return id == null ? null : pendingPaths?[id];
      }
      return path;
    };
  }

  Future<GlobalKey<FormBuilderState>> pump(
    WidgetTester tester, {
    dynamic value,
    ResolveMediaFn? mediaResolver,
    Map<int, String>? pendingAttachmentPaths,
  }) async {
    final key = GlobalKey<FormBuilderState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FormBuilder(
            key: key,
            child: AttachField(
              field: docField,
              value: value,
              mediaResolver: mediaResolver,
              pendingAttachmentPaths: pendingAttachmentPaths,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return key;
  }

  testWidgets('a pending marker labels from its staged file', (tester) async {
    await pump(
      tester,
      value: 'pending:7',
      mediaResolver: resolverReturning('/cache/whatever.pdf'),
      pendingAttachmentPaths: {7: '/outbox/staged.pdf'},
    );
    expect(find.text('staged.pdf'), findsOneWidget);
  });

  testWidgets('a cached file keeps the SERVER filename in the label, not the '
      'cache hash', (tester) async {
    // cachePathFor names files sha256(file_url); surfacing that would replace
    // "report.pdf" with 64 hex characters.
    await pump(
      tester,
      value: '/files/report.pdf',
      mediaResolver: resolverReturning('/cache/9f8e7d6c5b4a3f2e1d.pdf'),
    );
    expect(find.text('report.pdf'), findsOneWidget);
    expect(find.text('9f8e7d6c5b4a3f2e1d.pdf'), findsNothing);
  });

  testWidgets('the stored value is never mutated by display resolution', (
    tester,
  ) async {
    final key = await pump(
      tester,
      value: '/files/report.pdf',
      mediaResolver: resolverReturning('/cache/abc.pdf'),
    );
    expect(key.currentState?.fields['doc']?.value, '/files/report.pdf');
  });

  testWidgets('an unresolvable value still renders and keeps its value', (
    tester,
  ) async {
    final key = await pump(
      tester,
      value: '/files/absent.pdf',
      mediaResolver: resolverReturning(null),
    );
    expect(find.text('absent.pdf'), findsOneWidget);
    expect(key.currentState?.fields['doc']?.value, '/files/absent.pdf');
  });

  testWidgets('the resolver is invoked exactly once per value', (tester) async {
    // Regression guard: starting the resolve inside build() creates a new
    // future on every rebuild, and each completion triggers another rebuild —
    // an infinite loop that re-reads the cache and can re-download forever.
    await pump(
      tester,
      value: '/files/report.pdf',
      mediaResolver: resolverReturning('/cache/abc.pdf'),
    );
    await tester.pump();
    await tester.pump();
    expect(resolveCalls, ['/files/report.pdf']);
  });

  testWidgets('with no resolver the field still renders (host opt-in)', (
    tester,
  ) async {
    // Additive: hosts that never wire one keep the previous behaviour rather
    // than losing their preview.
    await pump(tester, value: '/uploads/report.pdf');
    expect(find.text('report.pdf'), findsOneWidget);
    expect(resolveCalls, isEmpty);
  });
}
