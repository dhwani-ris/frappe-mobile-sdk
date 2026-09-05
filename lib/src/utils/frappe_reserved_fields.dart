/// Frappe's reserved / framework-owned fieldnames, and the `frappe.scrub`
/// helper needed to derive the one that is doctype-dependent.
///
/// Used to keep the single-option preselect (see `SelectField` / `LinkField`)
/// off fields the framework owns: preselecting them writes a value the user
/// never chose into a slot Frappe assigns itself.
library;

/// Dart port of `frappe.scrub` (frappe/utils/data.py):
///
/// ```python
/// def scrub(txt: str) -> str:
///     return cstr(txt).replace(" ", "_").replace("-", "_").lower()
/// ```
///
/// Deliberately NOT [normalizeDoctypeTableName] (`database/table_name.dart`),
/// which additionally collapses every non-alphanumeric run to a single `_` and
/// strips leading/trailing `_`. That is correct for a SQLite identifier and
/// wrong here: `frappe.scrub` leaves apostrophes, slashes and repeated
/// separators alone, so a DocType named `Item's Group` yields the nestedset
/// parent field `parent_item's_group` — the table-name normalizer would
/// mispredict `parent_item_s_group` and the guard would miss the field.
String frappeScrub(String txt) =>
    txt.replaceAll(' ', '_').replaceAll('-', '_').toLowerCase();

/// Reserved fieldnames that are the same on every DocType.
///
/// Split by origin, because the two halves reach a form differently:
///
/// **`std_fields` pseudo-docfields** — `name`, `owner`, `modified_by` are
/// declared `Link` only in `frappe/model/__init__.py`'s `std_fields` list, to
/// render the Report Builder / filter UI. They are not DocFields (on disk they
/// are plain `varchar(140)`), and `Meta.get_link_fields()` —
/// `self.get("fields", {"fieldtype": "Link", "options": ["!=", "[Select]"]})` —
/// scans DocFields only, so they never appear in it. Frappe additionally
/// REFUSES to create a DocField with these names (`scrub_field_names()` throws
/// `InvalidFieldNameError` for a `restricted` tuple that contains all three),
/// so they cannot reach `meta.fields` at all. Listed anyway as a cheap
/// belt-and-braces: the SDK renders whatever meta it is handed.
///
/// **Conditional real DocFields** — added by `frappe/core/doctype/doctype/
/// doctype.py` when the DocType opts in, and therefore genuinely present in
/// `meta.fields`:
///
/// | Field          | Fieldtype | Options       | Added when              | Flags        |
/// |----------------|-----------|---------------|-------------------------|--------------|
/// | `amended_from` | Link      | self          | `is_submittable`        | `read_only`  |
/// | `old_parent`   | Link      | self          | `is_tree`               | `hidden`     |
/// | `auto_repeat`  | Link      | `Auto Repeat` | `allow_auto_repeat`     | `read_only`  |
///
/// `naming_series` is a Select and is convention rather than injection — the
/// DocType author declares it — but the name is reserved by that convention.
/// Frappe assigns it SERVER-SIDE at insert (`set_name_by_naming_series` →
/// `get_default_naming_series`, which returns the first TRUTHY option and
/// carries the comment *"Empty strings are used to avoid populating forms by
/// default"*). A client that preselects it defeats that.
///
/// The `is_tree` `parent_<scrubbed doctype>` field is doctype-dependent and so
/// is not in this set — see [isFrappeReservedField].
const frappeReservedFieldNames = <String>{
  // std_fields pseudo-docfields (also in Frappe's `restricted` tuple).
  'name',
  'owner',
  'modified_by',
  // Conditional real DocFields.
  'amended_from',
  'old_parent',
  'auto_repeat',
  // Convention.
  'naming_series',
};

/// Whether [fieldname] is a Frappe reserved / framework-owned field.
///
/// Pass [doctype] (the DocType's `name`, un-scrubbed) to also catch the
/// nestedset parent Link that `add_nestedset_fields()` adds to every
/// `is_tree` DocType. Frappe builds that fieldname as
/// `frappe.scrub(f"Parent {self.name}")`, so `Item Group` yields
/// `parent_item_group`. Without [doctype] the field is indistinguishable from
/// an ordinary `parent_*` field and is NOT flagged — `parent_company` on a
/// non-tree DocType is a perfectly normal user Link.
bool isFrappeReservedField(String? fieldname, {String? doctype}) {
  if (fieldname == null || fieldname.isEmpty) return false;
  if (frappeReservedFieldNames.contains(fieldname)) return true;
  if (doctype == null || doctype.trim().isEmpty) return false;
  return fieldname == frappeScrub('Parent $doctype');
}
