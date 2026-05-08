// Regression tests for LinkField null-safety contract.
//
// Root cause: before PR #39, loading and empty states used __blank__ as
// a sentinel initialValue, which leaked into submitted form data when the
// conversion guard was missed. These tests lock in the correct behaviour:
// no sentinel string ever appears in the form value map.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/searchable_select.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// ---------------------------------------------------------------------------
// Test doubles
// ---------------------------------------------------------------------------

/// Controls when getLinkOptions resolves, letting each test drive loading vs
/// empty vs options-loaded state independently.
class _FakeLinkOptionService extends LinkOptionService {
  final Completer<List<LinkOptionEntity>> _completer = Completer();

  _FakeLinkOptionService() : super(FrappeClient('https://fake.test'));

  @override
  Future<List<LinkOptionEntity>> getLinkOptions(
    String doctype, {
    bool forceRefresh = false,
    List<List<dynamic>>? filters,
  }) =>
      _completer.future;

  void resolve(List<LinkOptionEntity> options) {
    if (!_completer.isCompleted) _completer.complete(options);
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Widget _wrap(
  Widget child, {
  GlobalKey<FormBuilderState>? formKey,
}) {
  return MaterialApp(
    home: Scaffold(
      body: FormBuilder(
        key: formKey,
        child: child,
      ),
    ),
  );
}

DocField _linkField({String? linkFilters}) => DocField(
      fieldname: 'test_link',
      fieldtype: 'Link',
      label: 'Test Link',
      options: 'TestDocType',
      linkFilters: linkFilters,
    );

LinkOptionEntity _opt(String name) => LinkOptionEntity(
      doctype: 'TestDocType',
      name: name,
      label: name,
      lastUpdated: 0,
    );

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  // ---- Loading state -------------------------------------------------------

  group('LinkField — loading state', () {
    testWidgets(
      'form value is null (not __blank__) when there is no prior value',
      (tester) async {
        final formKey = GlobalKey<FormBuilderState>();
        final service = _FakeLinkOptionService();

        await tester.pumpWidget(_wrap(
          LinkField(
            field: _linkField(),
            linkOptionService: service,
          ),
          formKey: formKey,
        ));

        // Service completer is unresolved → widget stays in loading state.
        expect(
          formKey.currentState!.value['test_link'],
          isNull,
          reason: 'Loading state must not put __blank__ or any sentinel into form data',
        );
      },
    );

    testWidgets(
      'no __blank__ string in any form value during loading',
      (tester) async {
        final formKey = GlobalKey<FormBuilderState>();
        final service = _FakeLinkOptionService();

        await tester.pumpWidget(_wrap(
          LinkField(field: _linkField(), linkOptionService: service),
          formKey: formKey,
        ));

        for (final v in formKey.currentState!.value.values) {
          expect(
            v,
            isNot(equals('__blank__')),
            reason: 'Sentinel __blank__ must never appear in submitted form data',
          );
        }
      },
    );

    testWidgets(
      'prior value is displayed and no __blank__ item exists while loading',
      (tester) async {
        final service = _FakeLinkOptionService();

        await tester.pumpWidget(_wrap(
          LinkField(
            field: _linkField(),
            linkOptionService: service,
            value: 'Meghalaya',
          ),
        ));

        // The existing value must be visible so the UI doesn't flash.
        expect(find.text('Meghalaya'), findsOneWidget);

        // And no sentinel should appear in any dropdown item.
        final items = tester.widgetList<DropdownMenuItem<String>>(
          find.byType(DropdownMenuItem<String>),
        );
        for (final item in items) {
          expect(item.value, isNot(equals('__blank__')));
        }
      },
    );
  });

  // ---- Empty state ---------------------------------------------------------

  group('LinkField — empty state (no options returned)', () {
    testWidgets(
      'form value is null (not __blank__) when options list is empty',
      (tester) async {
        final formKey = GlobalKey<FormBuilderState>();
        final service = _FakeLinkOptionService();

        await tester.pumpWidget(_wrap(
          LinkField(field: _linkField(), linkOptionService: service),
          formKey: formKey,
        ));

        await tester.runAsync(() async => service.resolve([]));
        await tester.pump();

        expect(
          formKey.currentState!.value['test_link'],
          isNull,
          reason: 'Empty state must register null, not a sentinel string',
        );
      },
    );

    testWidgets(
      'no DropdownMenuItem carries __blank__ as its value',
      (tester) async {
        final service = _FakeLinkOptionService();

        await tester.pumpWidget(
          _wrap(LinkField(field: _linkField(), linkOptionService: service)),
        );

        await tester.runAsync(() async => service.resolve([]));
        await tester.pump();

        // Covers both loading and empty state items visible in the tree.
        final items = tester.widgetList<DropdownMenuItem<String>>(
          find.byType(DropdownMenuItem<String>),
        );
        for (final item in items) {
          expect(
            item.value,
            isNot(equals('__blank__')),
            reason: 'No DropdownMenuItem should carry __blank__ as its value',
          );
        }
      },
    );

    testWidgets(
      'onChanged emits null (not __blank__) when the hint item is tapped',
      (tester) async {
        dynamic captured = 'NOT_CALLED';
        final service = _FakeLinkOptionService();

        await tester.pumpWidget(_wrap(
          LinkField(
            field: _linkField(),
            linkOptionService: service,
            onChanged: (v) => captured = v,
          ),
        ));

        await tester.runAsync(() async => service.resolve([]));
        await tester.pump();

        // Open the dropdown (key set by _LinkFieldDropdownState).
        await tester.tap(find.byKey(const ValueKey('test_link_empty_false')));
        await tester.pumpAndSettle();

        // The hint item ("No options available") appears twice: once in the
        // button and once in the overlay. Tap the overlay instance.
        final hint = find.text('No options available');
        expect(hint, findsWidgets);
        await tester.tap(hint.last);
        await tester.pumpAndSettle();

        expect(
          captured,
          isNull,
          reason: 'onChanged must emit null, not __blank__ or any sentinel',
        );
      },
    );
  });

  // ---- Waiting-for-dependent state -----------------------------------------

  group('LinkField — waiting for dependent field', () {
    // link_filters references doc.state; formData has no 'state' key →
    // parseLinkFilters returns null → widget enters waiting state.
    const kLinkFilters = '[["District","state","=","eval: doc.state"]]';

    testWidgets(
      'shows dependent field name and hides refresh button',
      (tester) async {
        final service = _FakeLinkOptionService();

        await tester.pumpWidget(_wrap(
          LinkField(
            field: _linkField(linkFilters: kLinkFilters),
            linkOptionService: service,
            formData: {},
          ),
        ));
        await tester.pump(); // process setState from initState

        // Hint text appears in the button AND in the DropdownMenuItem overlay.
        expect(find.text('Select state first'), findsAtLeastNWidgets(1));
        expect(find.byIcon(Icons.refresh), findsNothing);
      },
    );

    testWidgets(
      'form value is null while waiting for dependent field',
      (tester) async {
        final formKey = GlobalKey<FormBuilderState>();
        final service = _FakeLinkOptionService();

        await tester.pumpWidget(_wrap(
          LinkField(
            field: _linkField(linkFilters: kLinkFilters),
            linkOptionService: service,
            formData: {},
          ),
          formKey: formKey,
        ));
        await tester.pump();

        expect(formKey.currentState!.value['test_link'], isNull);
      },
    );

    testWidgets(
      'loads options when dependent field value is supplied',
      (tester) async {
        final service = _FakeLinkOptionService();

        await tester.pumpWidget(_wrap(
          LinkField(
            field: _linkField(linkFilters: kLinkFilters),
            linkOptionService: service,
            formData: {'state': 'Meghalaya'}, // dependent value present
          ),
        ));

        // With the dependent value present the widget immediately starts
        // loading, not waiting.
        expect(find.text('Select state first'), findsNothing);
      },
    );
  });

  // ---- Options loaded state ------------------------------------------------

  group('LinkField — options loaded', () {
    testWidgets(
      'renders SearchableSelect (not a sentinel dropdown) after options load',
      (tester) async {
        final service = _FakeLinkOptionService();

        await tester.pumpWidget(
          _wrap(LinkField(field: _linkField(), linkOptionService: service)),
        );

        // Before resolve: should be in loading state (FormBuilderDropdown).
        expect(find.byType(SearchableSelect), findsNothing);

        await tester.runAsync(
          () async => service.resolve([_opt('Option A'), _opt('Option B')]),
        );
        await tester.pump();

        // After resolve: SearchableSelect replaces the loading dropdown.
        expect(find.byType(SearchableSelect), findsOneWidget);
        // The search TextField should be visible for the user to type.
        expect(find.byType(TextField), findsOneWidget);
        // No __blank__ sentinel in the widget tree.
        expect(find.text('__blank__'), findsNothing);
      },
    );

    testWidgets(
      'single option is auto-selected and fires onChanged with the value',
      (tester) async {
        dynamic captured = 'NOT_CALLED';
        final service = _FakeLinkOptionService();

        await tester.pumpWidget(_wrap(
          LinkField(
            field: _linkField(),
            linkOptionService: service,
            onChanged: (v) => captured = v,
          ),
        ));

        await tester.runAsync(
          () async => service.resolve([_opt('OnlyOption')]),
        );
        await tester.pump();
        // The auto-selection uses addPostFrameCallback; one extra pump fires it.
        await tester.pump();

        expect(
          captured,
          equals('OnlyOption'),
          reason: 'Single option must be auto-selected and surfaced via onChanged',
        );
      },
    );

    testWidgets(
      'onChanged emits null when selection is cleared',
      (tester) async {
        dynamic captured = 'NOT_CALLED';
        final service = _FakeLinkOptionService();

        await tester.pumpWidget(_wrap(
          LinkField(
            field: _linkField(),
            linkOptionService: service,
            value: 'Option A',
            onChanged: (v) => captured = v,
          ),
        ));

        await tester.runAsync(
          () async =>
              service.resolve([_opt('Option A'), _opt('Option B')]),
        );
        await tester.pump();

        // SearchableSelect exposes a clear action (empty selection → null).
        final searchableSelect = find.byType(SearchableSelect);
        expect(searchableSelect, findsOneWidget);
        // Trigger clear by passing empty list from SearchableSelect's onChanged
        // callback; the widget maps [] → null.
        final widget = tester.widget<SearchableSelect>(searchableSelect);
        widget.onChanged([]);
        await tester.pump();

        expect(captured, isNull);
      },
    );
  });
}
