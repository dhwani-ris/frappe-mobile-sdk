// Maps a Frappe DocField fieldtype to a SQLite column affinity.
// Returns null when the fieldtype has no parent-table column
// (layout breaks, buttons, or child tables stored in their own tables).

const _textTypes = <String>{
  'Data',
  'Small Text',
  'Long Text',
  'Text',
  'Code',
  'HTML',
  'JSON',
  'Read Only',
  'Color',
  'Select',
  'Barcode',
  'Link',
  'Dynamic Link',
  'Attach',
  'Attach Image',
  'Signature',
  'Geolocation',
};

const _integerTypes = <String>{'Int', 'Check', 'Duration'};

/// `Rating` belongs here, not with the integers: Frappe persists a Rating as a
/// **0..1 fraction** (`stars / max_stars`), so real values like `0.6` are the
/// norm, not the exception.
///
/// Declaring the column INTEGER did not corrupt anything in practice — SQLite's
/// type affinity keeps a value it cannot losslessly convert, so `0.6` was stored
/// as a real anyway — but the declared type contradicted the data and would
/// truncate under any stricter engine or affinity change. Existing installs keep
/// their INTEGER columns and continue to work for exactly that reason, so this
/// needs no migration.
const _realTypes = <String>{'Float', 'Currency', 'Percent', 'Rating'};

const _textDateTypes = <String>{'Date', 'Datetime', 'Time'};

const _noColumnTypes = <String>{
  'Section Break', 'Column Break', 'Tab Break', 'Heading', 'Button',
  'Table', 'Table MultiSelect',
  // Password values must never land in the on-device SQLite mirror —
  // sqflite is unencrypted, so persisting Password fields would expose
  // them on rooted/extracted devices. PullApply, schema generation, and
  // push payload assembly all key off `sqliteColumnTypeFor(...) == null`,
  // so this single mapping is the complete fix.
  'Password',
};

const _linkTypes = <String>{'Link', 'Dynamic Link'};
const _childTableTypes = <String>{'Table', 'Table MultiSelect'};

/// Returns the SQLite column type for a Frappe fieldtype, or null if
/// the fieldtype has no parent-table column.
String? sqliteColumnTypeFor(String fieldtype) {
  if (_noColumnTypes.contains(fieldtype)) return null;
  if (_textTypes.contains(fieldtype)) return 'TEXT';
  if (_integerTypes.contains(fieldtype)) return 'INTEGER';
  if (_realTypes.contains(fieldtype)) return 'REAL';
  if (_textDateTypes.contains(fieldtype)) return 'TEXT';
  return 'TEXT';
}

bool isLinkFieldType(String fieldtype) => _linkTypes.contains(fieldtype);

bool isChildTableFieldType(String fieldtype) =>
    _childTableTypes.contains(fieldtype);
