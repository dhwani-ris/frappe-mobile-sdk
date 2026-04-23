# Customization

This guide explains how to keep default UI or switch to configurable layouts/colors/typography.

## What is configurable now

- **Document list layout**: `DocumentListLayout.list` (current/default) or `DocumentListLayout.card`.
- **Document list visual style**: card color, title/subtitle text styles, button styles, FAB colors.
- **Form tab header layout**: classic `TabBar` (default) or stepper-style header.
- **Form section style**: section card color, padding/margins, fonts, field spacing.
- **Field label rendering**: show/hide external label and description.
- **Form action buttons**: save/delete button styling through `FormScreenStyle`.

## Material style label behavior (duplicate label fix)

`DefaultFormStyle.material` now avoids duplicate label rendering:

- external field label is hidden
- input uses hint text (placeholder/label fallback)

Use as-is:

```dart
FormScreen(
  meta: meta,
  repository: sdk.repository,
  syncService: sdk.sync,
  style: DefaultFormStyle.material,
)
```

If you create your own style, use:

```dart
FrappeFormStyle(
  showFieldLabel: false,
  fieldDecoration: (field) => InputDecoration(
    hintText: field.placeholder ?? field.label ?? field.fieldname,
    border: const UnderlineInputBorder(),
  ),
)
```

## Keep current tab layout vs stepper layout

Current behavior (default):

```dart
final style = DefaultFormStyle.standard; // tab bar layout
```

Stepper layout:

```dart
final style = FrappeFormStyle(
  tabHeaderLayout: FormTabHeaderLayout.stepper,
  stepHeaderStyle: const FormStepHeaderStyle(
    activeColor: Color(0xFF2DD4BF),
    inactiveColor: Color(0xFFD1D5DB),
  ),
);
```

Pass that style to `FormScreen(style: style)` or `FrappeFormBuilder(style: style)`.

## List page layout customization

```dart
DocumentListScreen(
  doctype: doctype,
  meta: meta,
  repository: sdk.repository,
  syncService: sdk.sync,
  metaService: sdk.meta,
  style: const DocumentListStyle(
    layout: DocumentListLayout.card, // or .list to keep current
    cardColor: Color(0xFFF8FAFC),
    titleStyle: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
    subtitleStyle: TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
    fabBackgroundColor: Color(0xFF0EA5E9),
    fabForegroundColor: Colors.white,
  ),
)
```

## Form screen button colors/styles

```dart
FormScreen(
  meta: meta,
  repository: sdk.repository,
  syncService: sdk.sync,
  screenStyle: FormScreenStyle(
    appBarBackgroundColor: const Color(0xFF111827),
    saveButtonStyle: TextButton.styleFrom(
      foregroundColor: const Color(0xFF2DD4BF),
    ),
    deleteIconColor: const Color(0xFFEF4444),
  ),
)
```

You can also pass the same form style through `DocumentListScreen`:

```dart
DocumentListScreen(
  // ...
  formStyle: DefaultFormStyle.material,
  formScreenStyle: const FormScreenStyle(
    deleteIconColor: Color(0xFFEF4444),
  ),
)
```

## Full form style options

`FrappeFormStyle` supports:

- `fieldDecoration`
- `labelStyle`, `descriptionStyle`, `sectionTitleStyle`
- `sectionMargin`, `sectionPadding`, `fieldPadding`
- `sectionTitleMaxLines`, `tabTitleMaxLines`
- `tabHeaderLayout`, `stepHeaderStyle`
- `showFieldLabel`, `showFieldDescription`
- `sectionCardColor`

## Extensibility points

- Custom field factory mapping for specific field types/field names.
- Custom field widgets for special behavior.
- Login screen styling with `LoginScreenStyle`.
- Runtime Link / Table MultiSelect filter overrides via `LinkFilterBuilder`.
  See `LINK_FILTER_BUILDER.md` for the API, wiring points
  (`MobileHomeScreen` / `FormScreen` / `DocumentListScreen` /
  `FrappeFormBuilder`), precedence rules, and examples.
- Field-edit hooks via `FieldChangeHandler` (`onFieldChange` on
  `FrappeFormBuilder`/`FormScreen`/`DocumentListScreen`, or per-doctype
  `getFieldChangeHandler` on `MobileHomeScreen`). Return a patch map to
  derive or cascade-clear fields; handlers receive a snapshot of form data
  so mutations never leak back into SDK state. See
  `FIELD_CHANGE_HANDLER.md`.

