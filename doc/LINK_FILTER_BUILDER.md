# Link Filter Builder

Runtime filter overrides for **Link** and **Table MultiSelect** fields.

Lets the host app supply dynamic filters at fetch time, overriding the static
`linkFilters` stored in DocType meta. Useful whenever valid options depend on
another field's value — in the same row, in the parent form, or on arbitrary
app state.

Introduced in [PR #35](https://github.com/dhwani-ris/frappe-mobile-sdk/pull/35).

---

## Table of Contents

1. [When to Use It](#1-when-to-use-it)
2. [Public API](#2-public-api)
3. [Precedence & Semantics](#3-precedence--semantics)
4. [Wiring It In](#4-wiring-it-in)
5. [Examples](#5-examples)
6. [Child Tables & `parentFormData`](#6-child-tables--parentformdata)
7. [Testing](#7-testing)
8. [Gotchas](#8-gotchas)
9. [API Reference](#9-api-reference)

---

## 1. When to Use It

Frappe's server-side `link_filters` are static JSON on a DocField, e.g.
`[["Warehouse", "company", "=", "My Co"]]`. They work for fixed filters but
**cannot**:

- Reference the live value of a sibling field (e.g. "filter items by the
  currently-selected item group").
- Reference parent-form fields from inside a child-table row (e.g. a
  Sales-Invoice-Item whose `item_code` should be filtered by the parent
  invoice's `customer`).
- Express conditional logic (e.g. "if `mode == A`, apply filter X; otherwise
  show everything").

On the web, Frappe Desk handles this via client-script `get_query`
callbacks. The mobile SDK has no JS runtime, so `LinkFilterBuilder` is its
declarative equivalent.

---

## 2. Public API

Both types are exported from the SDK barrel
(`package:frappe_mobile_sdk/frappe_mobile_sdk.dart`).

### `LinkFilterBuilder`

```dart
typedef LinkFilterBuilder = LinkFilterResult? Function(
  DocField field,
  String fieldName,
  Map<String, dynamic> rowData,
  Map<String, dynamic> parentFormData,
);
```

| Param             | Meaning                                                                       |
|-------------------|-------------------------------------------------------------------------------|
| `field`           | The `DocField` being fetched for. Use `field.options` for the target DocType. |
| `fieldName`       | Non-null field name of the link field (SDK guards this).                      |
| `rowData`         | The enclosing form's data snapshot. In a child row, this is the row map.      |
| `parentFormData`  | The parent form's data snapshot. Equals `rowData` at the top level.           |

### `LinkFilterResult`

```dart
class LinkFilterResult {
  final List<List<dynamic>>? filters;
  const LinkFilterResult({this.filters});
}
```

`filters` uses Frappe's filter list syntax:
`[[targetDoctype, fieldname, operator, value], ...]`.

### Lookup callback supplied to the SDK

Host widgets (`MobileHomeScreen`, `FormScreen`, `DocumentListScreen`,
`FrappeFormBuilder`) accept a **lookup** callback, not a single builder:

```dart
LinkFilterBuilder? Function(String doctype, String fieldname)
    getLinkFilterBuilder;
```

This keeps registration flexible — the app maps `(doctype, fieldname)` to a
builder however it likes (map lookup, code-generated table, etc.) and returns
`null` when no override exists.

---

## 3. Precedence & Semantics

Resolved by `LinkOptionService.resolveFilters`
(`lib/src/services/link_option_service.dart`):

```
1. Is getLinkFilterBuilder non-null AND field.fieldname non-null?
   ├── yes → builder = getLinkFilterBuilder(doctype, fieldname)
   │         ├── builder returns non-null LinkFilterResult
   │         │   └── use result.filters  (empty list normalizes to null)
   │         └── builder returns null
   │             └── fall through to meta linkFilters
   └── no  → parse meta linkFilters against rowData
```

### Return-value semantics

| Return value                             | Meaning                                              |
|------------------------------------------|------------------------------------------------------|
| `null` (from the builder itself)         | Fall back to meta `linkFilters`.                     |
| `LinkFilterResult(filters: null)`        | Explicit opt-out — ignore meta, fetch all records.   |
| `LinkFilterResult(filters: [])`          | Normalized to null — identical to opt-out.           |
| `LinkFilterResult(filters: [...])`       | Override meta with this list.                        |

### No lookup registered

If `getLinkFilterBuilder` is not supplied to the SDK, behavior is identical
to pre-PR-#35: meta `linkFilters` only. The hook is strictly additive.

---

## 4. Wiring It In

Thread the lookup through whichever entry-point widget your app uses. Pick
**one** — the SDK propagates it downward automatically through
`FrappeFormBuilder`, `FieldFactory`, `LinkField`, `TableMultiSelectField`,
and `LinkFieldCoordinator`.

### Via `MobileHomeScreen`

```dart
MobileHomeScreen(
  sdk: sdk,
  getLinkFilterBuilder: (doctype, fieldname) {
    return _registry[doctype]?[fieldname];
  },
  // ...other params
);
```

### Via `FormScreen`

```dart
FormScreen(
  sdk: sdk,
  doctype: 'Sales Invoice',
  getLinkFilterBuilder: (doctype, fieldname) => _registry[doctype]?[fieldname],
  // ...other params
);
```

### Via `DocumentListScreen`

```dart
DocumentListScreen(
  sdk: sdk,
  doctype: 'Sales Invoice',
  getLinkFilterBuilder: (doctype, fieldname) => _registry[doctype]?[fieldname],
  // ...other params
);
```

### Direct `FrappeFormBuilder`

If you embed `FrappeFormBuilder` yourself (e.g. in a custom screen):

```dart
FrappeFormBuilder(
  meta: meta,
  linkOptionService: sdk.linkOptions,
  getLinkFilterBuilder: (doctype, fieldname) => _registry[doctype]?[fieldname],
  // ...other params
);
```

### Registry shape (suggested)

The SDK does not dictate how you store builders. A two-level `Map` is the
simplest:

```dart
final Map<String, Map<String, LinkFilterBuilder>> _registry = {
  'Sales Invoice': {
    'customer': (field, fieldName, rowData, parentFormData) { ... },
  },
  'Sales Invoice Item': {
    'item_code': (field, fieldName, rowData, parentFormData) { ... },
  },
};
```

Any indirection that satisfies the `(String, String) → LinkFilterBuilder?`
signature works (code-generated registries, riverpod providers, etc.).

---

## 5. Examples

### Example 1 — Same-form dependent filter

Filter `warehouse` options by the currently-selected `company`:

```dart
LinkFilterBuilder warehouseByCompany = (field, fieldName, rowData, parentFormData) {
  final company = rowData['company'];
  if (company == null) return null; // fall back to meta
  return LinkFilterResult(filters: [
    ['Warehouse', 'company', '=', company],
  ]);
};
```

### Example 2 — Child-row filter using parent form

Filter a child-table Link by a value on the parent form. Inside a child row,
`rowData` is the row; `parentFormData` is the enclosing document:

```dart
LinkFilterBuilder itemByParentCustomer =
    (field, fieldName, rowData, parentFormData) {
  final customer = parentFormData['customer'];
  if (customer == null || customer.toString().isEmpty) {
    return const LinkFilterResult(filters: null); // no customer → show all
  }
  return LinkFilterResult(filters: [
    ['Item', 'customer', '=', customer],
  ]);
};
```

### Example 3 — Explicit opt-out of meta filters

A field whose meta has `link_filters` configured, but you want a
specific screen to show everything (e.g. an admin override):

```dart
LinkFilterBuilder showEverything =
    (field, fieldName, rowData, parentFormData) =>
        const LinkFilterResult(filters: null);
```

Difference versus returning plain `null`:
- `return null` → SDK applies meta `linkFilters`.
- `return LinkFilterResult(filters: null)` → SDK ignores meta, fetches all.

### Example 4 — Conditional fall-through

Apply a custom filter only in a specific mode; otherwise defer to meta:

```dart
LinkFilterBuilder villageByBlockWhenRestricted =
    (field, fieldName, rowData, parentFormData) {
  if (rowData['survey_mode'] != 'restricted') return null; // meta handles it
  return LinkFilterResult(filters: [
    ['Village', 'block', '=', rowData['block']],
  ]);
};
```

### Example 5 — Operators other than `=`

Filters support Frappe's standard operators (`in`, `like`, `!=`, `>=`, …):

```dart
LinkFilterResult(filters: [
  ['Item', 'item_group', 'in', ['Products', 'Services']],
  ['Item', 'disabled', '=', 0],
]);
```

All filters in the list are ANDed, matching Frappe server semantics.

---

## 6. Child Tables & `parentFormData`

For a top-level form, `rowData` and `parentFormData` refer to the same map
and have identical contents. Prefer `rowData` to make intent obvious.

For a **child-table row**, the SDK passes:

- `rowData` — the child row's own field values.
- `parentFormData` — the enclosing document's values at the time the fetch
  was triggered.

This is the only way to reference parent-form fields inside a child row. It
works for both `Table` and `Table MultiSelect` fields.

Implementation detail: `FrappeFormBuilder` computes
`effectiveParentFormData = widget.parentFormData ?? _formData` and threads
it to every nested child-row builder, so the value stays correct in
arbitrarily deep nesting.

---

## 7. Testing

Builders are plain Dart functions — test them without Flutter:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';

void main() {
  test('warehouse filter uses company', () {
    final result = warehouseByCompany(
      DocField(fieldname: 'warehouse', fieldtype: 'Link'),
      'warehouse',
      <String, dynamic>{'company': 'My Co'},   // rowData
      <String, dynamic>{'company': 'My Co'},   // parentFormData
    );
    expect(result?.filters, [
      ['Warehouse', 'company', '=', 'My Co'],
    ]);
  });

  test('returns null when dependency is missing', () {
    final result = warehouseByCompany(
      DocField(fieldname: 'warehouse', fieldtype: 'Link'),
      'warehouse',
      const <String, dynamic>{},
      const <String, dynamic>{},
    );
    expect(result, isNull);
  });
}
```

### In-SDK coverage

| Test file                                                      | Verifies                                           |
|----------------------------------------------------------------|----------------------------------------------------|
| `test/services/link_option_service_resolve_filters_test.dart`  | Precedence: hook result vs. meta fallback.         |
| `test/widgets/child_table_parent_filter_test.dart`             | `parentFormData` threading into child rows.        |
| `test/widgets/table_multi_select_hook_key_test.dart`           | Hook identity as widget key for correct rebuilds.  |
| `test/widgets/on_field_change_snapshot_test.dart`              | Snapshot isolation for data passed out of the SDK. |

---

## 8. Gotchas

1. **Don't mutate the arguments.** `rowData` and `parentFormData` are
   snapshots passed by the SDK — mutating them has no effect on form state.
   Treat them as read-only; use `onFieldChange` for field mutations.

2. **Don't close over stale state.** The builder is invoked at fetch time,
   not at registration time. Read dependency values from the
   `rowData` / `parentFormData` arguments, not from variables captured at
   construction.

3. **Filter target DocType matters.** The first element of each filter tuple
   is the **target** DocType (from `field.options`), not the DocType hosting
   the Link field.

4. **Empty-value handling is explicit.** Decide deliberately what happens
   when a dependency is empty:
   - `return LinkFilterResult(filters: null)` → show all.
   - `return null` → defer to meta.
   - `return LinkFilterResult(filters: [['Target','name','=','__never__']])`
     → show none.

5. **Return type is nullable `LinkFilterResult?`.** The outer function can
   also return `null`. These mean different things — see §3.

6. **Per-form dedup, not global cache.** Since PR #35,
   `LinkOptionService` no longer keeps a process-wide memory cache.
   `LinkFieldCoordinator` dedupes fetches per-form via its internal
   `_resultsCache`, so re-firing the builder with identical args within the
   same form won't re-hit the network. Builders are expected to be pure and
   cheap.

7. **Link and Table MultiSelect both honor the hook.** No separate
   registration — the same `(doctype, fieldname)` lookup works for both.
   For Table MultiSelect, pass the **child doctype's** fieldname (the Link
   field inside it), not the parent field.

8. **Purely additive.** Not providing `getLinkFilterBuilder` is valid and
   changes nothing — existing apps continue to use meta `linkFilters` only.

---

## 9. API Reference

### `LinkFilterResult`

File: `lib/src/models/link_filter_result.dart`

```dart
class LinkFilterResult {
  final List<List<dynamic>>? filters;
  const LinkFilterResult({this.filters});
}
```

Future-compatible: new fields (e.g. `limit`, `orderBy`, `mergeWithMeta`)
can be added as named parameters without breaking existing callers.

### `LinkFilterBuilder`

File: `lib/src/models/link_filter_result.dart`

```dart
typedef LinkFilterBuilder = LinkFilterResult? Function(
  DocField field,
  String fieldName,
  Map<String, dynamic> rowData,
  Map<String, dynamic> parentFormData,
);
```

### `LinkOptionService.resolveFilters`

File: `lib/src/services/link_option_service.dart`

```dart
static List<List<dynamic>>? resolveFilters({
  required DocField field,
  required Map<String, dynamic> rowData,
  required Map<String, dynamic> parentFormData,
  LinkFilterBuilder? hook,
});
```

Called internally by `LinkFieldCoordinator` and the Link / Table MultiSelect
widgets. Returns the resolved filter list to send to the server, or `null`
to fetch without filters.

### Host-widget lookup parameter

Accepted by:

- `MobileHomeScreen(getLinkFilterBuilder: ...)`
- `FormScreen(getLinkFilterBuilder: ...)`
- `DocumentListScreen(getLinkFilterBuilder: ...)`
- `FrappeFormBuilder(getLinkFilterBuilder: ...)`

Signature:

```dart
LinkFilterBuilder? Function(String doctype, String fieldname)?
    getLinkFilterBuilder;
```

---

## See Also

- `doc/FIELD_CHANGE_HANDLER.md` — sibling hook that fires on field edits
  (`onFieldChange`). Often paired with this one: clear a dependent Link in
  the change handler; filter its options here.
- `doc/FIELD_TYPES.md` — Link Field and Table MultiSelect Field rendering.
- `doc/CUSTOMIZATION.md` — other extensibility points.
- PR [#35](https://github.com/dhwani-ris/frappe-mobile-sdk/pull/35) — original
  change set and review discussion.
