# Field Types

This document covers the SDK's field type support, including specialized widgets
for Frappe field types that require custom rendering beyond simple text inputs.

## Supported Field Types

| Frappe Field Type | Widget | Notes |
|---|---|---|
| Data | DataField | Single-line text |
| Small Text / Text / Long Text | TextFieldWidget | Multi-line text |
| Int / Float / Currency / Percent | NumericField | Numeric keyboard |
| Date | DateField | Date picker |
| Datetime | DatetimeField | Date + time picker |
| Time | TimeField | Time picker |
| Duration | DurationField | HH:MM:SS input |
| Check | CheckField | Checkbox |
| Select / Multi Select | SelectField | Dropdown from field options |
| Link | LinkField | Type-ahead search (SearchableSelect) |
| Table | ChildTableField | Expandable child rows |
| Table MultiSelect | TableMultiSelectFieldBase | Chip-based multi-select |
| Geolocation | GeolocationField | GPS capture, stores GeoJSON |
| Phone | PhoneField | Numeric keyboard |
| Password | PasswordField | Obscured input |
| Rating | RatingField | Star rating |
| Image / Attach Image | ImageField | Image picker + preview |
| Attach | AttachField | File picker |
| HTML | HtmlField | Read-only HTML render |
| Button | ButtonField | Custom or server action |
| Read Only | ReadOnlyField | Display-only text |
| Section Break | — | Collapsible section header |
| Column Break | — | Responsive column layout |
| Tab Break | — | Tabbed navigation |

---

## SearchableSelect

A reusable type-ahead search widget used internally by Link fields and
Table MultiSelect fields.

**File:** `lib/src/ui/widgets/fields/searchable_select.dart`

### Modes

- **Single-select** (`multiSelect: false`): User types to search, picks one
  value, field collapses to show the selection. Tapping reopens search.
- **Multi-select** (`multiSelect: true`): Selected values display as chips.
  Search input stays visible to add more.

### Behavior

- Filters options by case-insensitive substring match
- Shows up to 8 suggestions at a time
- Uses `LinkOptionEntity` for options — displays `label` when available,
  falls back to `name`
- Option loading is the caller's responsibility; the widget is purely
  presentational

### Usage

SearchableSelect is not typically used directly by app code. It is used
internally by `LinkField` and `TableMultiSelectFieldBase`. If you need a
searchable dropdown in your custom widgets, you can use it:

```dart
SearchableSelect(
  options: linkOptions,        // List<LinkOptionEntity>
  selected: ['selected-id'],   // List<String>
  multiSelect: false,
  enabled: true,
  hintText: 'Search...',
  onChanged: (values) {
    // values is List<String> of selected option names
  },
)
```

---

## Link Field (with SearchableSelect)

Link fields connect to another DocType. When options are loaded from the
`LinkOptionService`, the field renders as a `SearchableSelect` in single-select
mode, providing type-ahead search instead of a plain dropdown.

**File:** `lib/src/ui/widgets/fields/link_field.dart`

### Rendering modes

1. **Direct options** (`options` parameter): Renders as `FormBuilderDropdown`.
   Used when the caller provides a fixed set of string options.
2. **Service-loaded options** (has `LinkOptionService`): Loads options from the
   local database or API, then renders as `SearchableSelect` with search.
3. **Fallback**: Text field with search icon if no service is available.

### Value resolution

When the field has an existing value, it matches against loaded options by
`name` first, then by `label`. Unknown values are preserved so existing
documents still display correctly.

---

## Table MultiSelect Field

Frappe's "Table MultiSelect" field type stores data as child-table rows, where
each row contains a Link field pointing to the target DocType.

**File:** `lib/src/ui/widgets/fields/table_multi_select_field.dart`

### How it works

1. Reads `field.options` to get the **child doctype name** (e.g.,
   "Patient Disease Category")
2. Loads the child doctype's meta via `getMeta()`
3. Finds the first Link field in the child doctype's fields
4. Loads options for that Link field's target doctype
5. Renders as `SearchableSelect` in multi-select mode (chips + search)

### Data format

Table MultiSelect fields store and emit data as `List<Map<String, dynamic>>`:

```dart
// Example: disease_category field with child doctype "Patient Disease Category"
// The child doctype has a Link field named "disease_category" → "Disease Category"
[
  {"disease_category": "Fever"},
  {"disease_category": "Diabetes"},
]
```

### Clean value emission

On initial load, the widget emits a clean `List<Map>` value through
`onChanged`. This fixes cases where corrupted string data (e.g., from Dart's
`.toString()` on a Map) may have been stored in the form data.

### Requirements

- `getMeta` must be provided in `FieldFactory.createField()` (via
  `FrappeFormBuilder.getMeta` or `FormScreen.metaService`)
- `LinkOptionService` is needed to load the selectable options

---

## Geolocation Field

Captures live GPS coordinates and stores them as a GeoJSON FeatureCollection
string — the format Frappe uses for Geolocation fields on web.

**File:** `lib/src/ui/widgets/fields/geolocation_field.dart`

### UI

- **"Fetch Location" button** — requests GPS permission and captures the
  device's current position
- **Coordinates card** — shows lat/lng (6 decimal places) in a green card
  when captured
- **Refresh button** — re-captures location
- **Clear button** — resets to null
- **Read-only mode** — shows coordinates or "No location captured"

### GeoJSON format

Stores data in the standard GeoJSON FeatureCollection format that Frappe
expects:

```json
{
  "type": "FeatureCollection",
  "features": [
    {
      "type": "Feature",
      "geometry": {
        "type": "Point",
        "coordinates": [longitude, latitude]
      },
      "properties": {}
    }
  ]
}
```

### Error handling

| Scenario | Behavior |
|---|---|
| GPS disabled | Shows "Location services are disabled. Please enable GPS." |
| Permission denied | Shows "Location permission denied." |
| Permanently denied | Shows "...Please enable in Settings." |
| Timeout (15s) | Shows "Failed to get location. Please try again." |

### Platform setup

Consuming apps must add platform permissions:

**Android** (`android/app/src/main/AndroidManifest.xml`):
```xml
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
```

**iOS** (`ios/Runner/Info.plist`):
```xml
<key>NSLocationWhenInUseUsageDescription</key>
<string>This app needs location access to capture geolocation data.</string>
```

### Dependency

The SDK includes `geolocator: ^13.0.2` for GPS access.

---

## DependsOn Expression Evaluator

The `DependsOnEvaluator` handles Frappe's `depends_on`, `mandatory_depends_on`,
and `read_only_depends_on` expressions for conditional field behavior.

**File:** `lib/src/utils/depends_on_evaluator.dart`

### Supported operators

| Operator | Example |
|---|---|
| `==` | `eval:doc.status == 'Active'` |
| `!=` | `eval:doc.status != 'Closed'` |
| `===` | `eval:doc.status === 'Active'` (JS strict equality) |
| `!==` | `eval:doc.status !== 'Closed'` (JS strict inequality) |
| `>`, `<`, `>=`, `<=` | `eval:doc.amount > 1000` |
| `&&` | `eval:doc.a == 1 && doc.b == 2` |
| `\|\|` | `eval:doc.a == 1 \|\| doc.b == 2` |
| `.includes()` | `eval:['A','B'].includes(doc.type)` |
| Truthy check | `eval:doc.fieldname` (non-empty, non-zero, non-null) |

### Type coercion

The evaluator compares values with a `toString()` fallback for `==` and `!=`
operators. This handles Frappe's common type mismatches where form data may
store a value as `int 1` while the expression compares against `String "1"`.

### JavaScript operator mapping

`===` and `!==` are JavaScript strict equality operators frequently used in
Frappe DocType `depends_on` expressions. In Dart, they map to the same behavior
as `==` and `!=` with the toString fallback. The evaluator checks for `===`
before `==` (and `!==` before `!=`) to avoid substring false matches.
