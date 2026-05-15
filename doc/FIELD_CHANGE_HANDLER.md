# Field Change Handler

The `FieldChangeHandler` callback lets the host app react to every field
edit inside a `FrappeFormBuilder`-rendered form and — if it wants —
**patch back** derived values. It's the SDK's declarative answer to what a
Frappe Desk client-script would do in `frm.script_manager` for `fieldname`.

Formalized as a typedef and tightened with snapshot-isolation semantics in
[PR #35](https://github.com/dhwani-ris/frappe-mobile-sdk/pull/35).

---

## Table of Contents

1. [When to Use It](#1-when-to-use-it)
2. [Public API](#2-public-api)
3. [The Patch-Map Contract](#3-the-patch-map-contract)
4. [Snapshot Isolation](#4-snapshot-isolation)
5. [Wiring It In](#5-wiring-it-in)
6. [Examples](#6-examples)
7. [Testing](#7-testing)
8. [Gotchas](#8-gotchas)
9. [Relationship to `LinkFilterBuilder`](#9-relationship-to-linkfilterbuilder)

---

## 1. When to Use It

Use `FieldChangeHandler` when field edits should trigger **computed
updates** on other fields in the same form:

- Cascade-clearing: clearing a parent Link should null out dependent
  children (`country` → `state` → `city`).
- Derived fields: `date_of_birth` changes → recompute `age`.
- Score totals: scoring sub-fields change → recompute a total.
- Conditional defaults: switching a mode flips default values on other
  fields.

It is **not** for:
- Validation — return your error from `onSubmit` / server; use
  `onFieldChange` only for deriving values.
- Fetching data — use link services / FrappeClient.
- Changing link-option filters — use `LinkFilterBuilder` (see §9).

---

## 2. Public API

Exported transitively via `package:frappe_mobile_sdk/frappe_mobile_sdk.dart`
(the barrel re-exports `form_builder.dart` which defines the typedef).

### `FieldChangeHandler`

```dart
typedef FieldChangeHandler = Map<String, dynamic>? Function(
  String fieldName,
  dynamic newValue,
  Map<String, dynamic> formData,
);
```

| Param        | Meaning                                                             |
|--------------|---------------------------------------------------------------------|
| `fieldName`  | The `fieldname` of the field that just changed.                     |
| `newValue`   | The field's new value, in the same Dart type the widget emits.      |
| `formData`   | A **snapshot** of the whole form's data *including* the new value.  |

**Return value:** `Map<String, dynamic>?`
- `null` → no patches; SDK does nothing.
- non-null map → SDK merges these entries into form data and re-renders
  affected fields.

The patch map is **keyed by fieldname**: `{ 'age': 42, 'city': null }`.

### Per-doctype lookup (`MobileHomeScreen`)

`MobileHomeScreen` accepts a resolver rather than a direct handler, because
it hosts multiple doctypes simultaneously:

```dart
FieldChangeHandler? Function(String doctype)? getFieldChangeHandler;
```

Return `null` for doctypes that don't need a handler.

---

## 3. The Patch-Map Contract

When your handler returns `{ 'foo': 1, 'bar': null }`, the SDK:

1. Applies `_formData.addAll(patches)` to its internal state.
2. Calls `_formKey.currentState?.patchValue(...)` on the underlying
   `flutter_form_builder` form key so affected field widgets repaint.
3. Does **not** re-invoke `onFieldChange` for the patched fields. Patches
   are terminal — they won't recursively trigger further handlers.
   If you need cascading logic, compute all downstream effects in a single
   handler call and return them together.

### Patch-value rules

- `null` clears a field (same effect as the user erasing it).
- Values must match the widget's expected Dart type (String for Data,
  int/double for Numeric, `List<Map>` for Table MultiSelect, etc.).
- Patching a field that is not in the current meta is a silent no-op.

### "No change" is cheap

Returning `null` from the handler is the fast path — the SDK skips the
patch pipeline entirely. Prefer early `return null` for field names you
don't care about:

```dart
(fieldName, newValue, formData) {
  if (fieldName != 'date_of_birth') return null;
  // ...compute age...
  return {'age': age};
}
```

---

## 4. Snapshot Isolation

The `formData` argument is a **fresh copy** of the SDK's internal form
state, taken just before your handler runs:

```dart
// from form_builder.dart
final patches = widget.onFieldChange?.call(
  field.fieldname!,
  value,
  Map<String, dynamic>.from(_formData),
);
```

Consequences:

- **Mutations don't leak.** Assigning `formData['sneaky'] = 'x'` inside
  your handler has zero effect on the SDK's state. This is verified by
  `test/widgets/on_field_change_snapshot_test.dart`.
- **The only way to change form state is to return a patch map.** This
  is by design — it makes data flow auditable and prevents "ghost writes"
  from handlers buried in your codebase.
- **Snapshot includes `newValue`.** The copy is taken *after* the new
  value is written to `_formData`, so `formData[fieldName] == newValue`.
  You don't need to special-case the changed field.

---

## 5. Wiring It In

Pick the entry point that matches how you render forms:

### Direct `FrappeFormBuilder`

```dart
FrappeFormBuilder(
  meta: meta,
  onFieldChange: (fieldName, newValue, formData) {
    // ...return patch map or null
  },
);
```

### `FormScreen`

```dart
FormScreen(
  sdk: sdk,
  doctype: 'Sales Order',
  onFieldChange: (fieldName, newValue, formData) { ... },
);
```

### `DocumentListScreen`

```dart
DocumentListScreen(
  sdk: sdk,
  doctype: 'Sales Order',
  onFieldChange: (fieldName, newValue, formData) { ... },
);
```

### `MobileHomeScreen` (per-doctype)

```dart
MobileHomeScreen(
  sdk: sdk,
  appTitle: 'My App',
  getFieldChangeHandler: (doctype) {
    switch (doctype) {
      case 'Sales Order':      return _salesOrderOnChange;
      case 'Purchase Invoice': return _purchaseInvoiceOnChange;
      default:                 return null;
    }
  },
);
```

The lookup resolver is called once per doctype screen the user opens —
returning `null` means "no handler" and is the correct default.

---

## 6. Examples

### Example 1 — Derive `age` from `date_of_birth`

```dart
FieldChangeHandler ageFromDob = (fieldName, newValue, formData) {
  if (fieldName != 'date_of_birth') return null;
  final dob = DateTime.tryParse(newValue?.toString() ?? '');
  if (dob == null) return {'age': 0};
  final now = DateTime.now();
  var age = now.year - dob.year;
  if (now.month < dob.month ||
      (now.month == dob.month && now.day < dob.day)) {
    age--;
  }
  return {'age': age < 0 ? 0 : age};
};
```

### Example 2 — Cascade-clear dependent Link fields

```dart
FieldChangeHandler cascadeClear = (fieldName, newValue, formData) {
  const chain = {
    'country': ['state', 'city'],
    'state':   ['city'],
  };
  final downstream = chain[fieldName];
  if (downstream == null) return null;
  return { for (final f in downstream) f: null };
};
```

### Example 3 — Recompute a score total

```dart
FieldChangeHandler recomputeTotal = (fieldName, newValue, formData) {
  const parts = ['reading', 'writing', 'math'];
  if (!parts.contains(fieldName)) return null;
  final total = parts.fold<int>(0, (sum, f) {
    final v = formData[f];
    if (v is int) return sum + v;
    if (v is double) return sum + v.toInt();
    return sum;
  });
  return {'total_score': total};
};
```

### Example 4 — Composing multiple handlers

`FrappeFormBuilder` accepts one handler per form. Compose inline:

```dart
FieldChangeHandler compose(List<FieldChangeHandler> handlers) {
  return (fieldName, newValue, formData) {
    final merged = <String, dynamic>{};
    for (final h in handlers) {
      final patches = h(fieldName, newValue, formData);
      if (patches != null) merged.addAll(patches);
    }
    return merged.isEmpty ? null : merged;
  };
}

final onFieldChange = compose([ageFromDob, cascadeClear, recomputeTotal]);
```

Later handlers see the **original** `formData` snapshot (patches from
earlier handlers aren't applied until the SDK merges the final map). If
handlers depend on each other's outputs, fold that logic into a single
handler instead.

### Example 5 — Conditional default

```dart
FieldChangeHandler modeDefaults = (fieldName, newValue, formData) {
  if (fieldName != 'mode') return null;
  if (newValue == 'express') {
    return {'shipping_method': 'Air', 'shipping_days': 1};
  }
  if (newValue == 'standard') {
    return {'shipping_method': 'Ground', 'shipping_days': 5};
  }
  return null;
};
```

---

## 7. Testing

Handlers are plain Dart functions — test without Flutter:

```dart
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('age is computed from date_of_birth', () {
    final result = ageFromDob(
      'date_of_birth',
      '2000-01-01',
      <String, dynamic>{'date_of_birth': '2000-01-01'},
    );
    expect(result?['age'], greaterThanOrEqualTo(24));
  });

  test('unrelated field triggers no patches', () {
    final result = ageFromDob('name', 'Alice', const <String, dynamic>{});
    expect(result, isNull);
  });

  test('handler mutating formData does not leak', () {
    final snapshot = <String, dynamic>{'name': 'Alice'};
    final handler = (String f, dynamic v, Map<String, dynamic> data) {
      data['sneaky'] = 'x';
      return null;
    };
    handler('name', 'Alice', snapshot);
    // Caller's map was mutated, but the SDK copies before calling you.
    // The SDK-side guarantee is verified in
    // test/widgets/on_field_change_snapshot_test.dart
  });
}
```

### In-SDK coverage

| Test file                                                 | Verifies                                        |
|-----------------------------------------------------------|-------------------------------------------------|
| `test/widgets/on_field_change_snapshot_test.dart`         | Handler mutations don't propagate to SDK state. |

---

## 8. Gotchas

1. **Return a patch map, not mutate in place.** Mutating `formData` does
   nothing — see §4.

2. **Patches are terminal.** A patch returned from `onFieldChange` does
   **not** re-trigger `onFieldChange` for the patched fields. If you need
   chained derivation (A → B → C), compute all of it in one handler.

3. **`null` vs empty map.** Both mean "no patches" from the SDK's
   perspective — `_formData.addAll({})` is a no-op and skips the repaint
   trigger. Prefer `null` for clarity and to make your intent explicit.

4. **Don't throw.** Exceptions in `onFieldChange` propagate out of the
   field's change callback. Catch and handle internally; a thrown
   exception can leave the form in an inconsistent state.

5. **Type the patch values correctly.** `{'age': '42'}` when `age` is an
   `Int` field will not render — pass the native Dart type the widget
   expects.

6. **Don't do async work.** The typedef is synchronous. If you need to
   fetch something, fire-and-forget the async call and return `null`, then
   patch in a follow-up via your own state management.

7. **Single handler per form.** If you need several, compose them (see
   Example 4). Handlers are run in the order you compose; each receives
   the original snapshot.

8. **Handler identity matters for rebuilds.** If you construct a new
   closure on every build (`onFieldChange: (...) { ... }` inline),
   Flutter will still use it correctly, but downstream widgets may rebuild
   more than necessary. Hoist stable handlers into `State` fields or
   top-level functions when possible.

---

## 9. Relationship to `LinkFilterBuilder`

Both hooks were formalized in PR #35 and share a design philosophy, but
they fire at different moments:

| Hook                   | When it fires                                 | What it returns                          |
|------------------------|-----------------------------------------------|------------------------------------------|
| `FieldChangeHandler`   | After a field value changes.                  | Patch map for other fields (or `null`).  |
| `LinkFilterBuilder`    | Before Link / Table MultiSelect options fetch.| Filter list (or opt-out / fall-through). |

Typical pairing: use `FieldChangeHandler` to **clear** a dependent Link
field when its parent changes, and `LinkFilterBuilder` to **filter** that
same Link's options based on the parent's current value. They compose
cleanly — clearing the child triggers a re-fetch, which re-invokes the
filter builder with the fresh parent value.

See `doc/LINK_FILTER_BUILDER.md`.
