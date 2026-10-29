import 'dart:math' as math;

import '../models/doc_field.dart';
import 'date_helpers.dart';

/// [value] the way Desk would hold [field]'s value when the document is saved:
/// - Date, Datetime and Time in Frappe's text format, empty as null
///   ([frappeTemporalValue]);
/// - with [roundNumbers], Float, Currency and Percent with a `precision`
///   rounded to it, as `ControlFloat.parse` does with `flt(value, precision)`.
///   The server stores what it receives without rounding.
/// Any other value is returned unchanged.
///
/// [roundNumbers] is OFF by default, which is what 2.0.0-beta.4 sent. Desk
/// rounds as the user TYPES, so its scripts compute from the rounded figure;
/// a host whose client scripts compute related values from the unrounded
/// figure would otherwise save a rounded field beside an unrounded one, and a
/// server check such as `abs(a - (b + c)) > 1e-6` refuses the save. Clamping a
/// value to another field (`flt(owner_total, 6)`) and rounding it up to a
/// 2-decimal precision likewise lands it above the limit it was clamped to.
Object? frappeSaveValue(
  DocField field,
  Object? value, {
  bool roundNumbers = false,
}) {
  final type = field.fieldtype;
  if (temporalFieldtypes.contains(type)) {
    return frappeTemporalValue(type, value);
  }
  final precision = field.precision;
  if (roundNumbers &&
      precision != null &&
      precision >= 0 &&
      value is num &&
      (type == 'Float' || type == 'Currency' || type == 'Percent')) {
    return frappeRound(value, precision);
  }
  return value;
}

/// Frappe's `_round` with its default method ("Banker's Rounding (legacy)")
/// and an explicit precision: the magnitude, first fixed to 8 decimals to drop
/// float noise, rounded half up, sign restored.
///
/// Half up at precision 0 too (2.5 → 3), as a Desk form saves it: `_round`
/// sends an exact half to the even neighbour only when `!precision`, and
/// `ControlFloat.get_precision()` passes the DocField's precision as it is in
/// the meta, a Select, so the string "0", which is truthy. The server's
/// `rounded(2.5, 0)` gives 2, but the server does not round on save.
num frappeRound(num value, int precision) {
  final m = math.pow(10, precision);
  final n = double.parse((value.abs() * m).toStringAsFixed(8));
  final r = n.round() / m;
  return value < 0 ? -r : r;
}
