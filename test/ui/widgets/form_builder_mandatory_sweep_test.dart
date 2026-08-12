import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';

/// Serves a fixed option list so a `Table MultiSelect` can actually be picked
/// from in a widget test (no DB, no resolver).
class _StubLinkOptionService extends LinkOptionService {
  _StubLinkOptionService(this._options) : super.withoutResolver();

  final List<LinkOptionEntity> _options;

  @override
  Future<List<LinkOptionEntity>> getLinkOptions(
    String doctype, {
    List<List<dynamic>>? filters,
  }) async => _options;
}

/// Legacy-mode submit must enforce the doctype's mandatory contract over the
/// COMPLETE payload, not just the widgets that happen to be mounted.
/// TabBarView builds tab pages lazily, so `state.saveAndValidate()` never sees
/// reqd fields on other tabs — without a meta-driven sweep those docs save
/// locally and bounce back as a server 417 at sync time.
void main() {
  /// Child doctype behind both the `Table` and the `Table MultiSelect` fields
  /// below: one inner Link field, which is what TMS resolves and stores.
  DocTypeMeta sectorRowMeta() => DocTypeMeta(
    name: 'Sector Row',
    label: 'Sector Row',
    isTable: true,
    fields: [
      DocField(fieldname: 'sector', fieldtype: 'Link', options: 'Sector'),
    ],
  );

  DocTypeMeta tmsMeta({bool twoTabs = false}) => DocTypeMeta(
    name: 'Test',
    label: 'Test',
    isTable: false,
    titleField: null,
    searchFields: null,
    fields: [
      if (twoTabs) ...[
        DocField(
          fieldname: 'tab_basic',
          fieldtype: 'Tab Break',
          idx: 1,
          label: 'Basic',
        ),
        DocField(fieldname: 'note', fieldtype: 'Data', idx: 2, label: 'Note'),
        DocField(
          fieldname: 'tab_details',
          fieldtype: 'Tab Break',
          idx: 3,
          label: 'Details',
        ),
      ],
      DocField(
        fieldname: 'sectors',
        fieldtype: 'Table MultiSelect',
        idx: 4,
        label: 'Sectors',
        reqd: true,
        options: 'Sector Row',
      ),
    ],
  );

  DocTypeMeta twoTabMeta({bool nameRequired = true}) => DocTypeMeta(
    name: 'Test',
    label: 'Test',
    isTable: false,
    titleField: null,
    searchFields: null,
    fields: [
      DocField(
        fieldname: 'tab_basic',
        fieldtype: 'Tab Break',
        idx: 1,
        label: 'Basic',
      ),
      DocField(
        fieldname: 'phone',
        fieldtype: 'Data',
        idx: 2,
        label: 'Phone',
        reqd: false,
      ),
      DocField(
        fieldname: 'tab_details',
        fieldtype: 'Tab Break',
        idx: 3,
        label: 'Details',
      ),
      DocField(
        fieldname: 'full_name',
        fieldtype: 'Data',
        idx: 4,
        label: 'Full Name',
        reqd: nameRequired,
      ),
    ],
  );

  Future<
    ({
      void Function() submit,
      List<Map<String, dynamic>> submitted,
      List<int> failed,
    })
  >
  pumpForm(
    WidgetTester tester,
    DocTypeMeta meta, {
    Map<String, dynamic> initialData = const {},
    Future<DocTypeMeta> Function(String doctype)? getMeta,
    LinkOptionService? linkOptionService,
  }) async {
    void Function()? captured;
    final submitted = <Map<String, dynamic>>[];
    final failed = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrappeFormBuilder(
            meta: meta,
            initialData: initialData,
            getMeta: getMeta,
            linkOptionService: linkOptionService,
            // Keep the coordinator's progress stream out of pumpAndSettle;
            // the TMS field reads linkOptionService directly.
            useLinkFieldCoordinator: false,
            onSubmit: submitted.add,
            onValidationFailed: () => failed.add(1),
            registerSubmit: (cb) => captured = cb,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (submit: captured!, submitted: submitted, failed: failed);
  }

  testWidgets('blocks submit when a reqd field on an UNMOUNTED tab is empty', (
    tester,
  ) async {
    final form = await pumpForm(tester, twoTabMeta());

    form.submit(); // user is on tab 1; full_name lives on tab 2
    await tester.pumpAndSettle();
    // flush the delayed inline-error invalidation timer
    await tester.pump(const Duration(milliseconds: 200));

    expect(form.submitted, isEmpty);
    expect(form.failed, hasLength(1));
  });

  testWidgets('switches to the tab containing the first missing field', (
    tester,
  ) async {
    final form = await pumpForm(tester, twoTabMeta());

    form.submit();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));

    final tabBar = tester.widget<TabBar>(find.byType(TabBar));
    expect(tabBar.controller!.index, 1);
  });

  testWidgets('submits when the reqd field on the other tab has a value', (
    tester,
  ) async {
    final form = await pumpForm(
      tester,
      twoTabMeta(),
      initialData: const {'full_name': 'Asha'},
    );

    form.submit();
    await tester.pumpAndSettle();

    expect(form.failed, isEmpty);
    expect(form.submitted, hasLength(1));
    expect(form.submitted.single['full_name'], 'Asha');
  });

  testWidgets('blocks submit when a reqd Table field has no rows', (
    tester,
  ) async {
    final meta = DocTypeMeta(
      name: 'Test',
      label: 'Test',
      isTable: false,
      titleField: null,
      searchFields: null,
      fields: [
        DocField(
          fieldname: 'sectors',
          fieldtype: 'Table',
          idx: 1,
          label: 'Sectors',
          reqd: true,
          options: 'Sector Row',
        ),
      ],
    );
    final form = await pumpForm(tester, meta);

    form.submit();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));

    expect(form.submitted, isEmpty);
    expect(form.failed, hasLength(1));
  });

  testWidgets(
    'blocks submit when mandatory_depends_on is satisfied and field is empty',
    (tester) async {
      final meta = DocTypeMeta(
        name: 'Test',
        label: 'Test',
        isTable: false,
        titleField: null,
        searchFields: null,
        fields: [
          DocField(
            fieldname: 'tab_basic',
            fieldtype: 'Tab Break',
            idx: 1,
            label: 'Basic',
          ),
          DocField(
            fieldname: 'want_training',
            fieldtype: 'Check',
            idx: 2,
            label: 'Want Training',
          ),
          DocField(
            fieldname: 'tab_details',
            fieldtype: 'Tab Break',
            idx: 3,
            label: 'Details',
          ),
          DocField(
            fieldname: 'training_topic',
            fieldtype: 'Data',
            idx: 4,
            label: 'Training Topic',
            mandatoryDependsOn: 'eval:doc.want_training==1',
          ),
        ],
      );
      final form = await pumpForm(
        tester,
        meta,
        initialData: const {'want_training': 1},
      );

      form.submit();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 200));

      expect(form.submitted, isEmpty);
      expect(form.failed, hasLength(1));
    },
  );

  testWidgets('reqd field hidden by depends_on does NOT block submit', (
    tester,
  ) async {
    final meta = DocTypeMeta(
      name: 'Test',
      label: 'Test',
      isTable: false,
      titleField: null,
      searchFields: null,
      fields: [
        DocField(
          fieldname: 'tab_basic',
          fieldtype: 'Tab Break',
          idx: 1,
          label: 'Basic',
        ),
        DocField(
          fieldname: 'is_msme',
          fieldtype: 'Check',
          idx: 2,
          label: 'MSME',
        ),
        DocField(
          fieldname: 'tab_details',
          fieldtype: 'Tab Break',
          idx: 3,
          label: 'Details',
        ),
        DocField(
          fieldname: 'udyam_number',
          fieldtype: 'Data',
          idx: 4,
          label: 'Udyam Number',
          reqd: true,
          dependsOn: 'eval:doc.is_msme==1',
        ),
      ],
    );
    final form = await pumpForm(
      tester,
      meta,
      initialData: const {'is_msme': 0},
    );

    form.submit();
    await tester.pumpAndSettle();

    expect(form.failed, isEmpty);
    expect(form.submitted, hasLength(1));
  });

  testWidgets('numeric zero counts as filled (Frappe parity)', (tester) async {
    final meta = DocTypeMeta(
      name: 'Test',
      label: 'Test',
      isTable: false,
      titleField: null,
      searchFields: null,
      fields: [
        DocField(
          fieldname: 'tab_basic',
          fieldtype: 'Tab Break',
          idx: 1,
          label: 'Basic',
        ),
        DocField(fieldname: 'note', fieldtype: 'Data', idx: 2, label: 'Note'),
        DocField(
          fieldname: 'tab_details',
          fieldtype: 'Tab Break',
          idx: 3,
          label: 'Details',
        ),
        DocField(
          fieldname: 'employee_count',
          fieldtype: 'Int',
          idx: 4,
          label: 'Employee Count',
          reqd: true,
        ),
      ],
    );
    final form = await pumpForm(
      tester,
      meta,
      initialData: const {'employee_count': 0},
    );

    form.submit();
    await tester.pumpAndSettle();

    expect(form.failed, isEmpty);
    expect(form.submitted, hasLength(1));
  });

  // ---------------------------------------------------------------------
  // Table MultiSelect: the sweep used to block submit for it with NO visible
  // message anywhere — TableMultiSelectFieldBase is not a FormBuilderField, so
  // `invalidate()` was a silent no-op and Save just did nothing.
  // ---------------------------------------------------------------------

  testWidgets(
    'reqd empty Table MultiSelect blocks submit AND shows an inline error',
    (tester) async {
      final form = await pumpForm(
        tester,
        tmsMeta(),
        getMeta: (_) async => sectorRowMeta(),
        linkOptionService: _StubLinkOptionService(const []),
      );

      form.submit();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 200));

      expect(form.submitted, isEmpty);
      expect(form.failed, hasLength(1));
      expect(
        find.text('Sectors is required'),
        findsOneWidget,
        reason:
            'a blocked submit must tell the user why — a dead Save button is '
            'worse than the 417 the sweep prevents',
      );
    },
  );

  testWidgets(
    'Table MultiSelect inline error survives the sweep switching tabs',
    (tester) async {
      // The discriminating case: the field is on tab 2, so it MOUNTS only after
      // the sweep switches tabs. On mount it emits its clean-value echo
      // (onChanged with an empty list) — treating that as an edit would wipe
      // the error on the very next frame and leave the user with nothing.
      final form = await pumpForm(
        tester,
        tmsMeta(twoTabs: true),
        getMeta: (_) async => sectorRowMeta(),
        linkOptionService: _StubLinkOptionService(const []),
      );

      form.submit();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();

      final tabBar = tester.widget<TabBar>(find.byType(TabBar));
      expect(tabBar.controller!.index, 1);
      expect(form.submitted, isEmpty);
      expect(find.text('Sectors is required'), findsOneWidget);
    },
  );

  testWidgets('Table MultiSelect error clears once the user picks a value', (
    tester,
  ) async {
    final form = await pumpForm(
      tester,
      tmsMeta(),
      getMeta: (_) async => sectorRowMeta(),
      linkOptionService: _StubLinkOptionService([
        LinkOptionEntity(
          doctype: 'Sector',
          name: 'AGRI',
          label: 'Agriculture',
          lastUpdated: 0,
        ),
      ]),
    );

    form.submit();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Sectors is required'), findsOneWidget);

    // Focus the search input so the suggestion list opens, then pick.
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Agriculture'));
    await tester.pumpAndSettle();

    expect(
      find.text('Sectors is required'),
      findsNothing,
      reason: 'adding a value must clear the pending required-empty error',
    );

    // And the form now submits with the picked row.
    form.submit();
    await tester.pumpAndSettle();
    expect(form.submitted, hasLength(1));
    expect(form.submitted.single['sectors'], [
      {'sector': 'AGRI'},
    ]);
  });

  testWidgets('reqd empty Table still shows its inline error (unchanged)', (
    tester,
  ) async {
    final meta = DocTypeMeta(
      name: 'Test',
      label: 'Test',
      isTable: false,
      titleField: null,
      searchFields: null,
      fields: [
        DocField(
          fieldname: 'sectors',
          fieldtype: 'Table',
          idx: 1,
          label: 'Sectors',
          reqd: true,
          options: 'Sector Row',
        ),
      ],
    );
    final form = await pumpForm(
      tester,
      meta,
      getMeta: (_) async => sectorRowMeta(),
    );

    form.submit();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));

    expect(form.submitted, isEmpty);
    expect(form.failed, hasLength(1));
    expect(find.text('Sectors is required'), findsOneWidget);
  });

  // The sweep is a SECOND evaluation of `mandatory_depends_on`, seventy lines
  // below `_isFieldRequired`. That one passes `onError: false`; the sweep called
  // `evaluate` bare and so took the `true` default. The two therefore disagreed
  // on an expression that cannot be evaluated: the widget marked the field
  // neither required nor asterisked, and the sweep blocked Save on it — a dead
  // Save button with no visible cause, which is the exact shape this PR fixes
  // for empty child tables.
  testWidgets('an unevaluatable mandatory_depends_on does NOT block submit', (
    tester,
  ) async {
    final meta = DocTypeMeta(
      name: 'Test',
      label: 'Test',
      isTable: false,
      titleField: null,
      searchFields: null,
      fields: [
        DocField(
          fieldname: 'sectors',
          fieldtype: 'Table',
          idx: 1,
          label: 'Sectors',
          options: 'Sector Row',
        ),
        DocField(
          fieldname: 'note',
          fieldtype: 'Data',
          idx: 2,
          label: 'Note',
          mandatoryDependsOn: "(doc.sectors || []).some(r => r.sector === 'X')",
        ),
      ],
    );
    final form = await pumpForm(
      tester,
      meta,
      getMeta: (_) async => sectorRowMeta(),
      // The row cell throws while being compared, so the `.some(...)` predicate
      // fails mid-evaluation exactly where a genuinely unparseable expression
      // would. `note` is left empty.
      initialData: {
        'sectors': [
          {'sector': _ThrowOnEquals()},
        ],
      },
    );

    form.submit();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));

    expect(
      form.failed,
      isEmpty,
      reason: 'a field the widget never marked required must not block Save',
    );
    expect(form.submitted, hasLength(1));
  });
}

/// Throws while being COMPARED, but stringifies normally — the narrowest hook
/// into `DependsOnEvaluator`'s failure path (`_compareValues` compares before it
/// stringifies), so the child-row widget can still render the cell.
class _ThrowOnEquals {
  @override
  bool operator ==(Object other) => throw StateError('comparison exploded');

  @override
  int get hashCode => 0;

  @override
  String toString() => 'boom';
}
