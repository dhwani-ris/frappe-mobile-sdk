/// A parsed offline query — `sql` is parameter-bound (every literal goes
/// through `params`), and is safe to pass directly to
/// `Database.rawQuery(sql, params)`. Spec §6.4.
class ParsedQuery {
  final String sql;
  final List<Object?> params;
  const ParsedQuery({required this.sql, required this.params});

  @override
  String toString() => 'ParsedQuery(sql=$sql, params=$params)';
}
