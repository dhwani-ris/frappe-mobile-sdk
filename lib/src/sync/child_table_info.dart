import '../database/table_name.dart';
import '../models/doc_type_meta.dart';

/// Canonical "(child doctype, child meta)" descriptor passed into the
/// pull/push/local-write paths whenever they need to walk a parent's
/// `Table` / `Table MultiSelect` fields and write the rows into the
/// child's `docs__<doctype>` mirror.
///
/// Consolidates three earlier copies of the same struct:
///
/// - `PullApply.PullApplyChildInfo` (now a typedef on this class)
/// - `payload_assembler.ChildInfo` (was an abstract class; now a typedef)
/// - `local_writer._ChildInfo` (private dup; deleted)
///
/// [tableName] is derived from [doctype] via [normalizeDoctypeTableName]
/// so callers don't have to compute it separately and the three paths
/// can't drift on the naming rule.
class ChildTableInfo {
  final String doctype;
  final DocTypeMeta meta;

  const ChildTableInfo(this.doctype, this.meta);

  String get tableName => normalizeDoctypeTableName(doctype);
}
