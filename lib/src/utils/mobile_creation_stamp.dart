import '../models/doc_type_meta.dart';

/// Fieldname of the mobile-side creation timestamp. Provisioned server-side as
/// a hidden, read-only `Datetime` Custom Field by `mobile_control`.
const String mobileCreatedAtField = 'mobile_created_at';

/// Fieldname of the mobile-side creation location. Provisioned server-side as
/// a hidden, read-only `Geolocation` Custom Field by `mobile_control`.
const String mobileLatitudeLongitudeField = 'mobile_latitude_longitude';

/// The wire format Frappe's `Datetime` fieldtype expects: naive local time,
/// space-separated, no timezone suffix and no `T`.
///
/// `DateTime.toIso8601String()` is deliberately NOT used — it emits the `T`
/// separator and, for a UTC instant, a trailing `Z`, neither of which Frappe
/// parses back into a Datetime column.
String formatFrappeDatetime(DateTime at) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${at.year}-${two(at.month)}-${two(at.day)} '
      '${two(at.hour)}:${two(at.minute)}:${two(at.second)}';
}

/// True when [meta] declares either capture field — i.e. when this DocType is
/// provisioned by `mobile_control` and there is something to capture.
///
/// Callers gate on this BEFORE starting a capture, not merely before writing
/// one. Reading GPS costs a permission prompt and a satellite fix, and neither
/// is acceptable on a form whose DocType has nowhere to put the result.
bool declaresCreationMeta(DocTypeMeta meta) {
  for (final f in meta.fields) {
    final name = f.fieldname;
    if (name == mobileCreatedAtField || name == mobileLatitudeLongitudeField) {
      return true;
    }
  }
  return false;
}

/// Writes the mobile creation metadata into a copy of [data].
///
/// Two guards make this safe to call on any payload, which is what lets the
/// call sites stay a single line each:
///
/// * **Meta-gated.** A value is written only when [meta] actually declares the
///   field. Servers without `mobile_control` (or with an older version of it)
///   never receive a key their DocType has no column for.
/// * **Never overwrites.** An existing non-blank value wins. The stamps record
///   when the record was *started*, so a re-save must not move them, and an
///   edit that round-trips the value through the form must not lose it.
///
/// A null [createdAt] or [latitudeLongitude] is simply not written — callers
/// pass null for "not captured", which is a normal outcome for the location
/// when permission is denied or no fix arrived in time.
Map<String, dynamic> stampCreationMeta({
  required DocTypeMeta meta,
  required Map<String, dynamic> data,
  String? createdAt,
  String? latitudeLongitude,
}) {
  final out = Map<String, dynamic>.from(data);
  final declared = <String>{
    for (final f in meta.fields)
      if (f.fieldname != null) f.fieldname!,
  };

  void put(String fieldname, String? value) {
    if (value == null || value.isEmpty) return;
    if (!declared.contains(fieldname)) return;
    final existing = out[fieldname];
    if (existing != null && existing.toString().trim().isNotEmpty) return;
    out[fieldname] = value;
  }

  put(mobileCreatedAtField, createdAt);
  put(mobileLatitudeLongitudeField, latitudeLongitude);
  return out;
}
