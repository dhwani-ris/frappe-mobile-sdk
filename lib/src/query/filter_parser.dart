import '../database/field_type_mapping.dart';
import '../database/normalize_for_search.dart';
import '../models/doc_type_meta.dart';
import 'filter_errors.dart';
import 'frappe_timespan.dart';
import 'parsed_query.dart';

/// Translates Frappe-style filter lists into a parameter-bound SQLite
/// `SELECT` against the local `docs__<doctype>` table. Spec §6.4.
///
/// **Pure** — no DB, no I/O. The `tableName` is whitelisted by caller
/// (typically [DoctypeMetaDao.getTableName]); columns are whitelisted
/// against `meta.fields` + a fixed system-column allowlist; values are
/// always passed through `params`, never string-concatenated.
///
/// Filter shapes accepted:
/// - `[col, op, value]` — the only supported triple.
/// - `[doctype, col, op, value]` — cross-doctype child filter; rejected
///   with [UnsupportedFilterError] so the caller knows to flatten.
class FilterParser {
  static const _allowedOps = <String>{
    '=',
    '!=',
    '<',
    '<=',
    '>',
    '>=',
    'in',
    'not in',
    'like',
    'not like',
    'between',
    'is',
    'is not',
    'timespan',
  };

  /// System columns present on every `docs__<doctype>` table — see
  /// `parent_schema.dart`. Filterable by the caller even though they
  /// aren't part of `meta.fields`.
  static const Map<String, String> _systemColumns = {
    'mobile_uuid': 'TEXT',
    'server_name': 'TEXT',
    'sync_status': 'TEXT',
    'sync_error': 'TEXT',
    'sync_attempts': 'INTEGER',
    'modified': 'TEXT',
    'local_modified': 'INTEGER',
    'pulled_at': 'INTEGER',
    'docstatus': 'INTEGER',
  };

  /// Extra system columns present only on child tables (`docs__<child>`) —
  /// see `child_schema.dart`. Added to the whitelist when `meta.isTable`.
  static const Map<String, String> _childSystemColumns = {
    'parent_uuid': 'TEXT',
    'parent_doctype': 'TEXT',
    'parentfield': 'TEXT',
    'idx': 'INTEGER',
  };

  static ParsedQuery toSql({
    required DocTypeMeta meta,
    required String tableName,
    required List<List> filters,
    List<List> orFilters = const [],
    String? orderBy,
    int page = 0,
    int pageSize = 50,
  }) {
    final colTypes = _columnTypes(meta);
    final normFields = meta.normFieldNames;
    final whereParts = <String>[];
    final params = <Object?>[];

    // Canonical messages — both filter and or_filter loops use the same
    // wording (including the "flatten to parent-field filters" hint that
    // the or_filter copy used to omit). Keeps caller-facing error text
    // consistent across the two unsupported-feature paths.
    const length4 =
        'Cross-doctype child-table filters '
        '[["Doctype","field","op","value"]] are not supported in v1; '
        'flatten to parent-field filters.';
    _parseAndCollect(
      filters,
      colTypes: colTypes,
      normFields: normFields,
      sqlParts: whereParts,
      params: params,
      malformedMessage: (f) =>
          'Malformed filter: $f (expected [col, op, value])',
      length4Message: length4,
    );

    final orParts = <String>[];
    _parseAndCollect(
      orFilters,
      colTypes: colTypes,
      normFields: normFields,
      sqlParts: orParts,
      params: params,
      malformedMessage: (f) =>
          'Malformed or_filter: $f (expected [col, op, value])',
      length4Message: length4,
    );

    final where = <String>[];
    where.addAll(whereParts);
    if (orParts.isNotEmpty) {
      where.add('(${orParts.join(' OR ')})');
    }

    final sb = StringBuffer('SELECT * FROM $tableName');
    if (where.isNotEmpty) {
      sb
        ..write(' WHERE ')
        ..write(where.join(' AND '));
    }
    if (orderBy != null && orderBy.isNotEmpty) {
      sb
        ..write(' ORDER BY ')
        ..write(_validateOrderBy(orderBy, colTypes));
    }
    sb
      ..write(' LIMIT ')
      ..write(pageSize)
      ..write(' OFFSET ')
      ..write(page * pageSize);
    return ParsedQuery(sql: sb.toString(), params: params);
  }

  /// Validates each filter row in [inputs] (rejecting 4-tuples with
  /// [length4Message], non-3-tuples via [malformedMessage]), dispatches
  /// each to [_parseOne], and appends the resulting SQL fragment to
  /// [sqlParts] and bind values to [params]. Shared by the `filters` and
  /// `orFilters` loops so a new tuple shape only requires editing this
  /// method instead of two parallel loops.
  static void _parseAndCollect(
    List<List<dynamic>> inputs, {
    required Map<String, String> colTypes,
    required Set<String> normFields,
    required List<String> sqlParts,
    required List<Object?> params,
    required String Function(List<dynamic>) malformedMessage,
    required String length4Message,
  }) {
    for (final f in inputs) {
      if (f.length == 4) {
        throw UnsupportedFilterError(length4Message);
      }
      if (f.length != 3) {
        throw FilterParseError(malformedMessage(f));
      }
      final parsed = _parseOne(f, colTypes, normFields);
      sqlParts.add(parsed.sql);
      params.addAll(parsed.params);
    }
  }

  /// Returns the canonical SQL `IFNULL($col, <empty>)` wrapper used to
  /// coalesce null column values before equality / LIKE comparisons.
  /// Picks `0` for numeric columns and `''` for text — sourced once so
  /// a future switch (e.g. to `COALESCE` or collation suffixes) applies
  /// to every text / numeric comparison site at once.
  static String _ifnullExpr(String col, bool isNumeric) =>
      isNumeric ? 'IFNULL($col, 0)' : "IFNULL($col, '')";

  /// Returns the canonical `col >= ? AND col <= ?` SQL fragment used by
  /// both the `between` and `timespan` operators.
  static ParsedQuery _rangeQuery(String col, Object? start, Object? end) =>
      ParsedQuery(sql: '$col >= ? AND $col <= ?', params: [start, end]);

  static ParsedQuery _parseOne(
    List f,
    Map<String, String> colTypes,
    Set<String> normFields,
  ) {
    final col = f[0] as String;
    final op = (f[1] as String).toLowerCase().trim();
    final value = f[2];

    if (!colTypes.containsKey(col)) {
      throw FilterParseError('Unknown column: $col');
    }
    if (!_allowedOps.contains(op)) {
      throw FilterParseError('Unsupported operator: $op');
    }

    final type = colTypes[col]!;
    final isNumeric = type == 'INTEGER' || type == 'REAL';

    switch (op) {
      case '=':
      case '!=':
        return ParsedQuery(
          sql: '${_ifnullExpr(col, isNumeric)} $op ?',
          params: [value],
        );
      case '<':
      case '<=':
      case '>':
      case '>=':
        return ParsedQuery(sql: '$col $op ?', params: [value]);
      case 'in':
      case 'not in':
        if (value is! List) {
          throw FilterParseError('"$op" requires a list value');
        }
        if (value.isEmpty) {
          return ParsedQuery(sql: op == 'in' ? '1=0' : '1=1', params: const []);
        }
        final placeholders = List.filled(value.length, '?').join(', ');
        final sqlOp = op == 'in' ? 'IN' : 'NOT IN';
        return ParsedQuery(
          sql: '$col $sqlOp ($placeholders)',
          params: value.cast<Object?>(),
        );
      case 'like':
      case 'not like':
        final sqlOp = op == 'like' ? 'LIKE' : 'NOT LIKE';
        if (normFields.contains(col)) {
          return ParsedQuery(
            sql: "IFNULL(${col}__norm, '') $sqlOp ?",
            params: [normalizeForSearch(value?.toString())],
          );
        }
        return ParsedQuery(
          sql: '${_ifnullExpr(col, false)} $sqlOp ?',
          params: [value],
        );
      case 'between':
        if (value is! List || value.length != 2) {
          throw const FilterParseError('"between" needs a 2-element list');
        }
        final start = _normalizeBetweenBound(
          value[0],
          isStart: true,
          type: type,
        );
        final end = _normalizeBetweenBound(
          value[1],
          isStart: false,
          type: type,
        );
        return _rangeQuery(col, start, end);
      case 'timespan':
        if (value == null) {
          throw const FilterParseError('"timespan" requires a keyword value');
        }
        final range = FrappeTimespan.resolve(value.toString());
        return _rangeQuery(col, range.start, range.end);
      case 'is':
        if (value == 'set') {
          return ParsedQuery(
            sql: "${_ifnullExpr(col, false)} != ''",
            params: const [],
          );
        }
        if (value == 'not set') {
          return ParsedQuery(
            sql: "${_ifnullExpr(col, false)} = ''",
            params: const [],
          );
        }
        if (value == null) {
          return ParsedQuery(sql: '$col IS NULL', params: const []);
        }
        throw FilterParseError(
          'Unsupported "is" value: $value '
          '(expected "set", "not set", or null)',
        );
      case 'is not':
        if (value == null) {
          return ParsedQuery(sql: '$col IS NOT NULL', params: const []);
        }
        throw FilterParseError(
          'Unsupported "is not" value: $value (expected null)',
        );
      default:
        throw FilterParseError('Unsupported operator: $op');
    }
  }

  /// Whitelist of legal column names → SQLite affinity. Built from
  /// `meta.fields` + system columns. Anything not in this map is
  /// rejected with [FilterParseError].
  static Map<String, String> _columnTypes(DocTypeMeta meta) {
    final map = <String, String>{};
    map.addAll(_systemColumns);
    if (meta.isTable) map.addAll(_childSystemColumns);
    for (final f in meta.fields) {
      final n = f.fieldname;
      if (n == null || n.isEmpty) continue;
      final sqlType = sqliteColumnTypeFor(f.fieldtype);
      if (sqlType == null) continue;
      map[n] = sqlType;
    }
    return map;
  }

  /// Accepts a single column (`'modified'`), a column + direction
  /// (`'modified DESC'`), or a comma-separated list of either
  /// (`'modified DESC, name ASC'`). Every column is whitelisted against
  /// [colTypes]; the only legal directions are `ASC` / `DESC`. Returns the
  /// normalized clause body (caller prefixes `ORDER BY `).
  static String _validateOrderBy(String orderBy, Map<String, String> colTypes) {
    final segments = orderBy.split(',');
    final validated = <String>[];
    for (final segment in segments) {
      final trimmed = segment.trim();
      if (trimmed.isEmpty) {
        throw FilterParseError('Empty ORDER BY segment in: "$orderBy"');
      }
      final parts = trimmed.split(RegExp(r'\s+'));
      if (parts.length > 2) {
        throw FilterParseError('Malformed ORDER BY segment: "$trimmed"');
      }
      final col = parts[0];
      if (!colTypes.containsKey(col)) {
        throw FilterParseError('Unknown ORDER BY column: $col');
      }
      final dir = parts.length > 1 ? parts[1].toUpperCase() : 'ASC';
      if (dir != 'ASC' && dir != 'DESC') {
        throw FilterParseError('ORDER BY direction must be ASC or DESC: $dir');
      }
      validated.add('$col $dir');
    }
    return validated.join(', ');
  }

  static Object? _normalizeBetweenBound(
    Object? v, {
    required bool isStart,
    required String type,
  }) {
    if (type != 'TEXT') return v;
    if (v is! String) return v;
    final hasTime = v.contains(':');
    if (hasTime) return v;
    return isStart ? '$v 00:00:00' : '$v 23:59:59';
  }
}
