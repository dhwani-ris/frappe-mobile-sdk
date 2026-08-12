import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';
import 'package:frappe_mobile_sdk/src/ui/form/form_controller.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/child_table_field.dart';

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

/// Reactive mode (`FormBuilderMode.reactive`) counterpart of
/// `test/ui/widgets/form_builder_mandatory_sweep_test.dart`.
///
/// `FormController.validate()` correctly blocks submit for a required-empty
/// child table, but neither `ChildTableField` ('Table') nor
/// `TableMultiSelectFieldBase` ('Table MultiSelect') is a `FormBuilderField`,
/// so nothing painted the message: Save silently did nothing. The reactive
/// path now feeds the controller's error into the same inline `errorText`
/// channel the legacy mandatory sweep uses, gated to those two fieldtypes.
void main() {
  DocTypeMeta sectorRowMeta() => DocTypeMeta(
    name: 'Sector Row',
    label: 'Sector Row',
    isTable: true,
    fields: [
      DocField(fieldname: 'sector', fieldtype: 'Link', options: 'Sector'),
    ],
  );

  DocTypeMeta singleFieldMeta({required String fieldtype, bool reqd = true}) =>
      DocTypeMeta(
        name: 'Test',
        label: 'Test',
        isTable: false,
        fields: [
          DocField(
            fieldname: 'sectors',
            fieldtype: fieldtype,
            idx: 1,
            label: 'Sectors',
            reqd: reqd,
            options: 'Sector Row',
          ),
        ],
      );

  Future<
    ({
      void Function() submit,
      List<Map<String, dynamic>> submitted,
      List<int> failed,
      FormController controller,
    })
  >
  pumpReactiveForm(
    WidgetTester tester,
    DocTypeMeta meta, {
    Map<String, dynamic> initialData = const {},
    Future<DocTypeMeta> Function(String doctype)? getMeta,
    LinkOptionService? linkOptionService,
  }) async {
    void Function()? captured;
    final submitted = <Map<String, dynamic>>[];
    final failed = <int>[];
    final controller = FormController(meta: meta, initialData: initialData);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrappeFormBuilder(
            meta: meta,
            mode: FormBuilderMode.reactive,
            controller: controller,
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
    return (
      submit: captured!,
      submitted: submitted,
      failed: failed,
      controller: controller,
    );
  }

  testWidgets(
    'reactive: reqd empty Table MultiSelect blocks submit AND paints an '
    'inline error that survives later frames',
    (tester) async {
      final form = await pumpReactiveForm(
        tester,
        singleFieldMeta(fieldtype: 'Table MultiSelect'),
        getMeta: (_) async => sectorRowMeta(),
        linkOptionService: _StubLinkOptionService(const []),
      );

      form.submit();
      await tester.pumpAndSettle();

      expect(form.submitted, isEmpty);
      expect(form.failed, hasLength(1));
      expect(
        find.text('Sectors is required'),
        findsOneWidget,
        reason:
            'a blocked submit must tell the user why — a dead Save button is '
            'worse than the 417 validation prevents',
      );

      // Survival check, not a formality: TableMultiSelectFieldBase pushes a
      // clean-value echo (onChanged with an empty list) once its loader
      // settles, and any rebuild/remount can re-fire it. If that echo were
      // treated as an edit the message would vanish on the next frame.
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.text('Sectors is required'), findsOneWidget);
    },
  );

  testWidgets(
    'reactive: reqd empty Table blocks submit AND paints an inline error '
    'that survives later frames',
    (tester) async {
      final form = await pumpReactiveForm(
        tester,
        singleFieldMeta(fieldtype: 'Table'),
        getMeta: (_) async => sectorRowMeta(),
      );

      form.submit();
      await tester.pumpAndSettle();

      expect(form.submitted, isEmpty);
      expect(form.failed, hasLength(1));
      expect(find.text('Sectors is required'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.text('Sectors is required'), findsOneWidget);
    },
  );

  testWidgets(
    'reactive: Table MultiSelect error survives MOUNTING after the failed '
    'submit (clean-value echo must not wipe it)',
    (tester) async {
      // The discriminating case. On tab 2 the field is unmounted when submit
      // fails, so it mounts with the error ALREADY set and immediately fires
      // its clean-value echo (`onChanged([])`) — the exact sequence that wiped
      // the legacy error before it was guarded. It also proves the seeding
      // path: validate() only pushes to error notifiers that already exist,
      // and this field's is created on mount, after validation ran.
      final meta = DocTypeMeta(
        name: 'Test',
        label: 'Test',
        isTable: false,
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
            fieldname: 'sectors',
            fieldtype: 'Table MultiSelect',
            idx: 4,
            label: 'Sectors',
            reqd: true,
            options: 'Sector Row',
          ),
        ],
      );
      final form = await pumpReactiveForm(
        tester,
        meta,
        getMeta: (_) async => sectorRowMeta(),
        linkOptionService: _StubLinkOptionService(const []),
      );

      form.submit();
      await tester.pumpAndSettle();
      expect(form.submitted, isEmpty);
      expect(form.failed, hasLength(1));
      // Reactive submit does not switch tabs (it only focuses + scrolls), so
      // nothing is painted yet — the field is not built.
      expect(find.text('Sectors is required'), findsNothing);

      expect(form.controller.getValue('sectors'), isNull);
      await tester.tap(find.text('Details'));
      await tester.pumpAndSettle();
      // Proof the echo really landed while the error was showing: the value
      // went from null to an empty list purely from mounting the widget.
      expect(form.controller.getValue('sectors'), isEmpty);

      expect(find.text('Sectors is required'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.text('Sectors is required'), findsOneWidget);
    },
  );

  testWidgets(
    'reactive: Table MultiSelect error clears once the user picks a value, '
    'then submit proceeds',
    (tester) async {
      final form = await pumpReactiveForm(
        tester,
        singleFieldMeta(fieldtype: 'Table MultiSelect'),
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
      expect(find.text('Sectors is required'), findsOneWidget);

      // Focus the search input so the suggestion list opens, then pick.
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Agriculture'));
      await tester.pumpAndSettle();

      expect(
        find.text('Sectors is required'),
        findsNothing,
        reason: 'supplying a value must clear the required-empty error',
      );

      form.submit();
      await tester.pumpAndSettle();
      expect(form.submitted, hasLength(1));
      expect(form.submitted.single['sectors'], [
        {'sector': 'AGRI'},
      ]);
    },
  );

  testWidgets(
    'reactive: Table error clears once rows are added, then submit proceeds',
    (tester) async {
      final form = await pumpReactiveForm(
        tester,
        singleFieldMeta(fieldtype: 'Table'),
        getMeta: (_) async => sectorRowMeta(),
      );

      form.submit();
      await tester.pumpAndSettle();
      expect(find.text('Sectors is required'), findsOneWidget);

      // Report a row exactly the way the row-edit sheet does — through the
      // widget's own onChanged — without driving the whole bottom-sheet flow.
      tester.widget<ChildTableField>(find.byType(ChildTableField)).onChanged!([
        {'sector': 'AGRI'},
      ]);
      await tester.pumpAndSettle();

      expect(find.text('Sectors is required'), findsNothing);

      form.submit();
      await tester.pumpAndSettle();
      expect(form.submitted, hasLength(1));
      expect(form.submitted.single['sectors'], [
        {'sector': 'AGRI'},
      ]);
    },
  );

  testWidgets(
    'reactive: a non-child-table reqd field is untouched by the inline '
    'error channel',
    (tester) async {
      // Measured pre-change baseline for a reqd Data field in reactive mode:
      // a blocked submit paints NOTHING (reactive submit validates via the
      // controller and never runs flutter_form_builder's validators), and the
      // field's OWN validator shows the message once the user interacts
      // (AutovalidateMode.onUserInteraction). Both must still hold — the new
      // errorText channel must not leak here, or the message double-renders.
      final meta = DocTypeMeta(
        name: 'Test',
        label: 'Test',
        isTable: false,
        fields: [
          DocField(
            fieldname: 'full_name',
            fieldtype: 'Data',
            idx: 1,
            label: 'Full Name',
            reqd: true,
          ),
        ],
      );
      final form = await pumpReactiveForm(tester, meta);

      form.submit();
      await tester.pumpAndSettle();

      expect(form.submitted, isEmpty);
      expect(form.failed, hasLength(1));
      expect(
        form.controller.errorOf('full_name'),
        'Full Name is required',
        reason: 'the controller still computes the error',
      );
      expect(
        find.text('Full Name is required'),
        findsNothing,
        reason:
            'unchanged: reactive submit does not paint FormBuilderField errors',
      );

      // Its own validator still fires on interaction — exactly once.
      await tester.enterText(find.byType(TextField).first, 'x');
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '');
      await tester.pumpAndSettle();
      expect(find.text('Full Name is required'), findsOneWidget);
    },
  );

  testWidgets('reactive: a NON-required child table never paints an error', (
    tester,
  ) async {
    final form = await pumpReactiveForm(
      tester,
      singleFieldMeta(fieldtype: 'Table MultiSelect', reqd: false),
      getMeta: (_) async => sectorRowMeta(),
      linkOptionService: _StubLinkOptionService(const []),
    );

    form.submit();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(find.text('Sectors is required'), findsNothing);
    expect(form.failed, isEmpty);
    expect(form.submitted, hasLength(1));
  });
}
