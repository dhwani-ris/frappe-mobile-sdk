// Maps a Frappe DocField fieldtype to a SQLite column affinity.
// Returns null when the fieldtype has no parent-table column
// (layout breaks, buttons, or child tables stored in their own tables).

const _textTypes = <String>{
  'Data', 'Small Text', 'Long Text', 'Text', 'Code', 'HTML', 'JSON',
  'Read Only', 'Password', 'Color', 'Select', 'Barcode',
  'Link', 'Dynamic Link', 'Attach', 'Attach Image', 'Signature',
  'Geolocation',
};

const _integerTypes = <String>{
  'Int', 'Check', 'Duration', 'Rating',
};

const _realTypes = <String>{
  'Float', 'Currency', 'Percent',
};

const _textDateTypes = <String>{
  'Date', 'Datetime', 'Time',
};

const _noColumnTypes = <String>{
  'Section Break', 'Column Break', 'Tab Break', 'Heading', 'Button',
  'Table', 'Table MultiSelect',
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
