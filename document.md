# SDK Changes Document

> This document describes all patches made to `frappe_mobile_sdk` during field use with a Frappe v16 mobile app. Each change is a **generic SDK improvement** — none are specific to any particular project. They fix bugs, add missing Frappe field type support, and improve UX.
>
> **For reviewers:** Each section explains What changed, Why it's needed, and How to implement it. The changes should be applied to the `develop` branch.

---

## Table of Contents

1. [DependsOn Evaluator: `===` / `!==` support + toString fallback](#1-dependson-evaluator----support--tostring-fallback)
2. [FormBuilder: patchValue after onFieldChange (computed field UI sync)](#2-formbuilder-patchvalue-after-onfieldchange-computed-field-ui-sync)
3. [FormBuilder: fetch_from trigger for pre-filled Link fields](#3-formbuilder-fetch_from-trigger-for-pre-filled-link-fields)
4. [FormBuilder: Table/TMS default empty value should be `[]` not `''`](#4-formbuilder-tabletms-default-empty-value-should-be--not-)
5. [FormScreen: Skip Table/TMS in multi-select comma normalization](#5-formscreen-skip-tabletms-in-multi-select-comma-normalization)
6. [New Widget: SearchableSelect (type-ahead search for Link fields)](#6-new-widget-searchableselect-type-ahead-search-for-link-fields)
7. [LinkField: Replace FormBuilderDropdown with SearchableSelect](#7-linkfield-replace-formbuilderdropdown-with-searchableselect)
8. [New Widget: TableMultiSelectField (proper TMS rendering)](#8-new-widget-tablemultiselectfield-proper-tms-rendering)
9. [FieldFactory: Route TMS and Geolocation to correct widgets](#9-fieldfactory-route-tms-and-geolocation-to-correct-widgets)
10. [New Widget: GeolocationField (GPS capture)](#10-new-widget-geolocationfield-gps-capture)

---

## 1. DependsOn Evaluator: `===` / `!==` support + toString fallback

**File:** `lib/src/utils/depends_on_evaluator.dart`

### What

Two changes to the `DependsOnEvaluator`:

**a) Add `===` and `!==` operator support.**
Frappe's `depends_on` expressions often use JavaScript strict equality operators (`===`, `!==`). The evaluator only handled `==` and `!=`. Since `===` contains `==` as a substring, the `===` check must come **before** the `==` check to avoid a false partial match.

**b) Add `.toString()` fallback in `_compareValues` for `==` and `!=`.**
Frappe form data often has type mismatches (e.g., a field value is `int 1` but the expression compares against `String "1"`). The original `_compareValues` used Dart's `==` which is type-strict. Adding a `toString()` fallback handles these cross-type comparisons correctly.

### Why

Without `===`/`!==` support, any `depends_on` expression using these operators (common in Frappe DocType definitions) silently falls through to the truthy check, causing fields to show/hide incorrectly. For example, `eval:doc.status !== 'Closed'` would be evaluated as a truthy check on `status` instead of a comparison.

Without the toString fallback, `_compareValues(1, "1", "==")` returns `false` even though Frappe treats them as equal. This causes field visibility issues where `depends_on: eval:doc.some_check == 1` fails when the form stores the Check value as the string `"1"`.

### How to implement

In `_compareValues`:
```dart
case '==':
  if (actual == expected) return true;
  // Fallback: compare as strings (handles int vs String mismatches)
  return actual?.toString() == expected?.toString();
case '!=':
  if (actual == expected) return false;
  return actual?.toString() != expected?.toString();
```

For `===`/`!==`, add two new blocks **before** the existing `==` and `!=` blocks:
```dart
// Handle === (must be before == check)
if (expr.contains(' === ')) {
  final parts = expr.split(' === ');
  if (parts.length == 2) {
    // ... same logic as ==, using _compareValues with '=='
  }
}

// Handle !== (must be before != check)
if (expr.contains(' !== ')) {
  final parts = expr.split(' !== ');
  if (parts.length == 2) {
    // ... same logic as !=, using _compareValues with '!='
  }
}
```

In Dart, `===` and `!==` have no semantic difference from `==` and `!=` — they're just JS syntax that Frappe uses. Map them to the same comparison logic.

---

## 2. FormBuilder: patchValue after onFieldChange (computed field UI sync)

**File:** `lib/src/ui/widgets/form_builder.dart`

### What

After calling `widget.onFieldChange()` and merging patches into `_formData`, also call `_formKey.currentState?.patchValue(patches)` to sync the UI.

### Why

The `onFieldChange` callback lets app code compute derived field values (e.g., BMI from height/weight, blood pressure classification from systolic/diastolic readings). The original code correctly updated `_formData` (so the values save correctly), but did **not** call `patchValue` on the FormBuilder state. This means visible computed fields (like a "BP Category" text field) would not update in the UI until the form was rebuilt for another reason. The data was correct internally but the user couldn't see it.

### How to implement

In the `onChanged` callback inside `_buildFieldWidget`, find the block:
```dart
if (patches != null && patches.isNotEmpty) {
  _formData.addAll(patches);
}
```

Change it to:
```dart
if (patches != null && patches.isNotEmpty) {
  _formData.addAll(patches);
  // Sync UI state so visible fields reflect computed values.
  _formKey.currentState?.patchValue(patches);
}
```

---

## 3. FormBuilder: fetch_from trigger for pre-filled Link fields

**File:** `lib/src/ui/widgets/form_builder.dart`

### What

Extract the "trigger fetch_from for already-populated Link fields" logic into a helper method `_triggerFetchFromForPrefilledLinks()`, and call it from both `initState` and `didUpdateWidget`.

### Why

When a form opens with `initialData` that already contains Link field values (e.g., a Vital Signs form pre-filled with `patient: "PAT-001"`), the `fetch_from` mechanism doesn't fire because `onChanged` is never called — the value was set at init, not by user interaction. Fields like `patient_name` (which has `fetch_from: "patient.patient_name"`) stay blank even though the patient link is populated.

This affects any workflow where forms are opened with pre-filled Link values (e.g., navigating from a list screen with a linked document, or chaining form creation where one form pre-fills the next).

### How to implement

Add a helper method:
```dart
/// Trigger fetch_from for Link fields that already have values in _formData
/// so dependent fields (e.g. patient_name from patient) get populated.
void _triggerFetchFromForPrefilledLinks() {
  if (widget.fetchLinkedDocument == null) return;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!mounted) return;
    for (final field in widget.meta.fields) {
      if (field.fieldtype == 'Link' && field.fieldname != null) {
        final val = _formData[field.fieldname];
        if (val != null && val.toString().trim().isNotEmpty) {
          _handleFetchFrom(field.fieldname!, val);
        }
      }
    }
  });
}
```

Call it at the end of `initState()` (after `_buildFormStructure` and `TabController` creation) and at the end of the `didUpdateWidget` block that rebuilds the form (after `_tabController` recreation).

---

## 4. FormBuilder: Table/TMS default empty value should be `[]` not `''`

**File:** `lib/src/ui/widgets/form_builder.dart`

### What

In `_handleSubmit()` and `_getCurrentFormData()`, when building `completeFormData` with default values for all fields, use `<dynamic>[]` as the default for `Table` and `Table MultiSelect` field types instead of `''`.

### Why

Table and Table MultiSelect fields expect `List` values. When they default to `''` (empty string), downstream code that expects a List (e.g., `value is List ? ... : ...`) takes the wrong branch. This causes the Table MultiSelect field widget to receive a String instead of a List, leading to type errors or empty renders.

### How to implement

In both `_handleSubmit()` and `_getCurrentFormData()`, change:
```dart
(field.fieldtype == 'Check' ? 0 : '');
```
to:
```dart
(field.fieldtype == 'Check' ? 0 :
    (field.fieldtype == 'Table' || field.fieldtype == 'Table MultiSelect') ? <dynamic>[] : '');
```

---

## 5. FormScreen: Skip Table/TMS in multi-select comma normalization

**File:** `lib/src/ui/form_screen.dart`

### What

In `_handleSubmit`, the multi-select normalization loop converts `List` values to comma-separated strings for Frappe. Add a skip for `Table` and `Table MultiSelect` fields — they must remain as `List<Map>`.

### Why

Frappe expects plain multi-select values as comma-separated strings (e.g., `"Option A,Option B"`), but Table and Table MultiSelect fields must be sent as JSON arrays of objects (e.g., `[{"disease_category": "Fever"}, {"disease_category": "Diabetes"}]`). Without this skip, TMS child-table data gets flattened into a string like `"{disease_category: Fever},{disease_category: Diabetes}"`, which Frappe can't parse — corrupting the saved data.

### How to implement

In `_handleSubmit`, find:
```dart
if (f.allowMultiple && name != null && payload[name] is List) {
  payload[name] = (payload[name] as List)
      .map((e) => e.toString())
      .join(',');
}
```

Change to:
```dart
if (f.allowMultiple && name != null && payload[name] is List) {
  final ft = f.fieldtype;
  if (ft == 'Table' || ft == 'Table MultiSelect') continue;
  payload[name] = (payload[name] as List)
      .map((e) => e.toString())
      .join(',');
}
```

---

## 6. New Widget: SearchableSelect (type-ahead search for Link fields)

**New file:** `lib/src/ui/widgets/fields/searchable_select.dart`

### What

A reusable, self-contained searchable select widget. Supports two modes:
- **Single-select:** Type-ahead search, pick one value, collapses to show selection.
- **Multi-select:** Chip display for selected values, search to add more.

### Why

The original Link field uses `FormBuilderDropdown`, which is a native Flutter dropdown. On Frappe sites with hundreds or thousands of link options (e.g., Patient, Employee, Medication), scrolling through a flat dropdown is unusable. A type-ahead search lets users find the right option by typing a few characters.

This widget is also reused by the Table MultiSelect field (change #8) for its chip-based multi-select UI.

### How to implement

Create a new `StatefulWidget` called `SearchableSelect` that:
- Takes `List<LinkOptionEntity> options`, `List<String> selected`, `ValueChanged<List<String>> onChanged`, `bool multiSelect`, `bool enabled`, `bool loading`, `String? hintText`
- Shows a `TextField` for search input with filtered suggestions in a dropdown overlay
- In single-select mode: shows current selection as an `InputDecorator`, tapping opens search
- In multi-select mode: shows `Chip` widgets for selections, with search below
- Filters options by case-insensitive substring match, limits to 8 visible suggestions
- Options list uses `LinkOptionEntity` (already exists in SDK) — shows `label` if available, falls back to `name`

The widget should be purely presentational — option loading is the caller's responsibility.

---

## 7. LinkField: Replace FormBuilderDropdown with SearchableSelect

**File:** `lib/src/ui/widgets/fields/link_field.dart`

### What

Replace the `FormBuilderDropdown` in `_LinkFieldDropdownState.build()` (the case when options are loaded and available) with the `SearchableSelect` widget from change #6.

### Why

FormBuilderDropdown renders all options in a native dropdown menu. For doctypes with many records (hundreds of Patients, Medications, etc.), this creates:
1. Poor UX — scrolling through hundreds of items in a tiny dropdown
2. Performance issues — Flutter renders all DropdownMenuItems at once
3. No search — users can't type to filter

SearchableSelect provides type-ahead filtering, showing only 8 matches at a time.

### How to implement

In `_LinkFieldDropdownState.build()`, replace the final `FormBuilderDropdown` block (where `_options` is populated) with:
```dart
// Resolve current value from options
final currentVal = widget.value?.toString();
final selected = <String>[];
if (currentVal != null && currentVal.isNotEmpty) {
  final match = _options.any((o) => o.name == currentVal)
      ? currentVal
      : _options
          .where((o) => o.label == currentVal)
          .map((o) => o.name)
          .firstOrNull;
  if (match != null) selected.add(match);
  // Keep unknown values so existing docs still display
  if (match == null) selected.add(currentVal);
}

return SearchableSelect(
  options: _options,
  selected: selected,
  multiSelect: false,
  enabled: widget.enabled && !widget.field.readOnly,
  hintText: widget.field.placeholder ??
      'Search ${widget.field.displayLabel}...',
  onChanged: (values) {
    widget.onChanged?.call(values.isEmpty ? null : values.first);
  },
);
```

Add `import 'searchable_select.dart';` at the top of the file.

---

## 8. New Widget: TableMultiSelectField (proper TMS rendering)

**New file:** `lib/src/ui/widgets/fields/table_multi_select_field.dart`

### What

A proper field widget for Frappe's "Table MultiSelect" field type. Renders using `SearchableSelect` in multi-select mode (chips + search).

### Why

The original SDK routes `Table MultiSelect` fields to `SelectField`, which is designed for plain `Select` fields with a fixed set of string options. But Table MultiSelect is fundamentally different:

1. **Data structure:** TMS stores data as a list of child-table rows (`[{"linked_field": "Value1"}, {"linked_field": "Value2"}]`), not a comma-separated string.
2. **Options source:** TMS options come from a linked DocType (defined in the child table's Link field), not from a static options list.
3. **Child doctype resolution:** The widget must load the child doctype's meta to find which Link field provides the options.

The original SelectField can't handle any of this — it shows an empty dropdown because the `field.options` contains a child doctype name (e.g., `"Patient Disease Category"`) instead of a newline-separated option list.

### How to implement

Create `TableMultiSelectFieldBase extends BaseField` that:
1. Takes `List<dynamic> rows`, `Future<DocTypeMeta> Function(String) getMeta`, `LinkOptionService? linkOptionService`
2. Internally uses a `_Loader` stateful widget that:
   - Loads child doctype meta via `getMeta(field.options!)`
   - Finds the first Link field in the child doctype's fields
   - Loads options for that Link field's target doctype
   - Renders `SearchableSelect` in multi-select mode
3. Extracts selected values from rows: `rows.map((r) => r[linkFieldName]).toList()`
4. On change, converts selected values back to rows: `values.map((v) => {linkFieldName: v}).toList()`
5. On initial load, emits a clean `List<Map>` value back through `onChanged` to fix any corrupted string values that may have been stored (e.g., Dart `.toString()` artifacts)

---

## 9. FieldFactory: Route TMS and Geolocation to correct widgets

**File:** `lib/src/ui/widgets/fields/field_factory.dart`

### What

Two routing changes in the `switch` statement:

**a) Table MultiSelect → TableMultiSelectFieldBase**
Remove `'Table MultiSelect'` from the `Select` / `Multi Select` case group. Add a new case:
```dart
case 'Table MultiSelect':
  if (getMeta == null) return null;
  final tmsRows = value is List
      ? List<dynamic>.from(value)
      : <dynamic>[];
  return TableMultiSelectFieldBase(
    field: field,
    rows: tmsRows,
    onChanged: onChanged,
    enabled: enabled,
    getMeta: getMeta,
    linkOptionService: linkOptionService,
    style: fieldStyle,
  );
```

**b) Geolocation → GeolocationField**
Add a new case before the default:
```dart
case FieldTypes.geolocation:
  return GeolocationField(
    field: field,
    value: value,
    onChanged: onChanged,
    enabled: enabled,
    style: fieldStyle,
  );
```

Add imports for `table_multi_select_field.dart` and `geolocation_field.dart`.

### Why

**TMS:** Without this, Table MultiSelect fields render as a broken SelectField (empty dropdown, wrong data format). The dedicated widget handles child-doctype resolution, proper List<Map> data format, and chip-based multi-select UX.

**Geolocation:** Without this, Geolocation fields fall through to the default case (read-only DataField showing raw GeoJSON text). The dedicated widget provides GPS capture UI.

---

## 10. New Widget: GeolocationField (GPS capture)

**New file:** `lib/src/ui/widgets/fields/geolocation_field.dart`
**File:** `lib/src/constants/field_types.dart` (add constant)
**File:** `pubspec.yaml` (add dependency)

### What

A field widget for Frappe's `Geolocation` field type. Captures live GPS coordinates and stores them as a GeoJSON FeatureCollection string — the format Frappe expects.

### Why

Frappe's Geolocation field type stores location data as GeoJSON. On web, Frappe uses a Leaflet map widget. On mobile, there's no equivalent — the field falls through to the default case and shows raw JSON text. A GPS-powered widget is the natural mobile equivalent: capture device location with one tap.

### How to implement

**a) Add field type constant** in `field_types.dart`:
```dart
static const String geolocation = 'Geolocation';
```

**b) Add dependency** in `pubspec.yaml`:
```yaml
# GPS location for Geolocation field type
geolocator: ^13.0.2
```

**c) Create `GeolocationField extends BaseField`** with a stateful inner widget that:

- **Parses existing GeoJSON** value on init to extract lat/lng for display
- **"Fetch Location" button** → checks GPS enabled → requests permission → captures position via `Geolocator.getCurrentPosition()`
- **Displays coordinates** in a green card when captured (lat, lng to 6 decimal places)
- **Stores as GeoJSON FeatureCollection:**
  ```json
  {
    "type": "FeatureCollection",
    "features": [{
      "type": "Feature",
      "geometry": {
        "type": "Point",
        "coordinates": [longitude, latitude]
      },
      "properties": {}
    }]
  }
  ```
- **Error handling:** GPS disabled, permission denied, permanently denied (directs to Settings), timeout (15s)
- **Read-only mode:** Shows captured coordinates without fetch button; shows "No location captured" if empty
- **Clear button:** Resets to null
- **Refresh button:** Re-fetches location when already captured

**Platform setup required by consuming apps:**
- Android: `ACCESS_FINE_LOCATION` + `ACCESS_COARSE_LOCATION` in `AndroidManifest.xml`
- iOS: `NSLocationWhenInUseUsageDescription` in `Info.plist`

---

## Summary of files

| # | File | Type | Changes |
|---|------|------|---------|
| 1 | `lib/src/utils/depends_on_evaluator.dart` | Modified | `===`/`!==` support, toString fallback |
| 2 | `lib/src/ui/widgets/form_builder.dart` | Modified | patchValue after onFieldChange, fetch_from init helper, Table/TMS default `[]` |
| 3 | `lib/src/ui/form_screen.dart` | Modified | Skip Table/TMS in multi-select normalization |
| 4 | `lib/src/ui/widgets/fields/searchable_select.dart` | **New** | Reusable type-ahead search widget |
| 5 | `lib/src/ui/widgets/fields/link_field.dart` | Modified | Use SearchableSelect instead of FormBuilderDropdown |
| 6 | `lib/src/ui/widgets/fields/table_multi_select_field.dart` | **New** | Proper TMS field with child-doctype resolution |
| 7 | `lib/src/ui/widgets/fields/field_factory.dart` | Modified | Route TMS + Geolocation to correct widgets |
| 8 | `lib/src/ui/widgets/fields/geolocation_field.dart` | **New** | GPS capture field |
| 9 | `lib/src/constants/field_types.dart` | Modified | Add `geolocation` constant |
| 10 | `pubspec.yaml` | Modified | Add `geolocator` dependency |
