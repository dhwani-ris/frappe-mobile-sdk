class AddedField {
  final String name;

  /// SQLite column type — TEXT|INTEGER|REAL.
  final String sqlType;

  const AddedField({required this.name, required this.sqlType});
}

class MetaDiff {
  final String doctype;
  final List<AddedField> addedFields;
  final List<String> removedFields;
  final List<String> typeChanged;

  /// Field names needing a `<field>__is_local INTEGER` companion column.
  final List<String> addedIsLocalFor;

  /// Field names needing a `<field>__norm TEXT` companion column + backfill
  /// from existing rows.
  final List<String> addedNormFor;

  final List<String> indexesToDrop;

  const MetaDiff({
    required this.doctype,
    required this.addedFields,
    required this.removedFields,
    required this.typeChanged,
    required this.addedIsLocalFor,
    required this.addedNormFor,
    required this.indexesToDrop,
  });

  bool get isNoOp =>
      addedFields.isEmpty &&
      removedFields.isEmpty &&
      typeChanged.isEmpty &&
      addedIsLocalFor.isEmpty &&
      addedNormFor.isEmpty &&
      indexesToDrop.isEmpty;
}
