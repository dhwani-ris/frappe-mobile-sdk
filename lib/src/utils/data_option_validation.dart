import 'translate.dart';

// Frappe's own checks, ported from frappe/utils/__init__.py (version-15):
// `split_emails`, `validate_email_address`, `parse_addr`, `check_format`,
// `validate_name`, `validate_phone_number` and `validate_url`, as
// `BaseDocument._validate_data_fields` runs them on save.

// EMAIL_MATCH_PATTERN, which Frappe compiles with re.IGNORECASE. Spelled out
// here: under IGNORECASE Python's [a-z] also matches U+0130, U+0131, U+017F
// and U+212A, which Dart's `caseSensitive: false` does not. Frappe applies it
// with `re.match`, anchored at the start only, so trailing text after a valid
// address passes ("a@example.com." and "a@example.com!" are accepted).
const String _az = 'a-zA-Z0-9\u0130\u0131\u017F\u212A';
const String _local = "$_az!#\$%&'*+/=?^_`{|}~-";
final RegExp _emailMatch = RegExp(
  '^[$_local]+(?:\\.[$_local]+)*@(?:[$_az](?:[$_az-]*[$_az])?\\.)+'
  '[$_az](?:[$_az-]*[$_az])?',
);
// EMAIL_STRING_PATTERN: parse_addr's fallback search.
final RegExp _emailString = RegExp(
  r'([a-zA-Z0-9_.+-]+@[a-zA-Z0-9-]+\.[a-zA-Z0-9-.]+)',
);
// MULTI_EMAIL_STRING_PATTERN: a comma outside double quotes ends an address.
final RegExp _multiEmail = RegExp(r'[,\n](?=(?:[^"]|"[^"]*")*$)');
final RegExp _lineBreaks = RegExp(r'[\t\n\r]');
// The two shapes whose `email.utils.parseaddr` result is reproduced exactly:
// a bare address, and "Name <address>" (plain or one quoted phrase).
final RegExp _plainAddress = RegExp(
  r'^[^ ()<>,:;"\[\]\\@]+@[^ ()<>,:;"\[\]\\@]+$',
);
final RegExp _angleAddress = RegExp(
  r'^(?:[^()<>,:;"\[\]\\@]*| *"[^"\\]*" *)'
  r'<([^ ()<>,:;"\[\]\\@]+@[^ ()<>,:;"\[\]\\@]+)>$',
);
// Holds local@x.y as a subsequence. The address Frappe checks is built from
// the part's own characters, in order, so a part without one cannot pass.
final RegExp _mayHoldAddress = RegExp(
  '[$_local][\\s\\S]*@[\\s\\S]*[$_az][\\s\\S]*\\.[\\s\\S]*[$_az]',
);

final RegExp _phone = RegExp(r'^([0-9 +_\-,.*#()]){1,20}$');

// PERSON_NAME_PATTERN. Python's \w is a letter (\p{L}), a number (\p{N}) or
// "_", and NOT a combining mark (\p{M}): Frappe refuses a name with a vowel
// sign or virama, such as "किशोर", or with a combining accent.
final RegExp _name = RegExp(
  r"^[\p{L}\p{N}_][\p{L}\p{N}_'\-]*( [\p{L}\p{N}_][\p{L}\p{N}_'\-]*)*$",
  unicode: true,
);

const String _schemeChars =
    'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+-.';
// urllib.parse.uses_params: schemes whose path drops a `;params` tail.
const Set<String> _usesParams = {
  '',
  'ftp',
  'hdl',
  'prospero',
  'http',
  'imap',
  'https',
  'shttp',
  'rtsp',
  'rtspu',
  'sip',
  'sips',
  'mms',
  'sftp',
  'tel',
};

/// The error Frappe gives on save for [value] in a Data field whose options
/// are Email, Phone, Name or URL (`BaseDocument._validate_data_fields`), or
/// null when Frappe accepts the value, it is empty, or the options name no
/// check.
///
/// Offline the SDK would only hear that error at sync, with the record stuck
/// in the outbox; checking on the form catches it while the user is there.
///
/// A value made of spaces only is checked as Frappe checks it: an Email list
/// with no address passes, while Name, Phone and URL refuse it.
String? dataOptionError(String? options, String? value) {
  if (value == null || value.isEmpty) return null;
  switch (options) {
    case 'Email':
      return _emailError(value);
    case 'Phone':
      final v = value.trim();
      return _phone.hasMatch(v)
          ? null
          : sdkTr('{0} is not a valid Phone Number', [v]);
    case 'Name':
      final v = value.trim();
      return _name.hasMatch(v) ? null : sdkTr('{0} is not a valid Name', [v]);
    case 'URL':
      return _frappeAcceptsUrl(value)
          ? null
          : sdkTr("'{0}' is not a valid URL", [value]);
    default:
      return null;
  }
}

/// `split_emails` then `validate_email_address` on each address.
String? _emailError(String value) {
  // Tabs and line breaks become spaces first, so "a@x.com\nb@y.org" is one
  // address with a space in it, which Frappe refuses.
  final text = value.replaceAll(_lineBreaks, ' ');
  for (final item in text.split(_multiEmail)) {
    // Frappe's `strip` also drops BOMs and zero-width spaces anywhere.
    final address = item
        .replaceAll('\uFEFF', '')
        .replaceAll('\u200B', '')
        .trim();
    if (address.isEmpty) continue;
    // validate_email_address then splits on EVERY comma, quoted or not, so
    // `"Doe, John" <j@example.com>` is refused at `"Doe`, as Frappe does.
    for (final raw in address.split(',')) {
      final part = raw.trim();
      if (!_frappeAcceptsEmail(part)) {
        return sdkTr('{0} is not a valid Email Address', [part]);
      }
    }
  }
  return null;
}

/// `validate_email_address`'s `_check` for one comma-separated [part].
bool _frappeAcceptsEmail(String part) {
  if (part.isEmpty) return false;
  // Returned as "not an address" without raising, so the save goes through.
  if (part.contains('undisclosed-recipient')) return true;
  if (part.contains(' ') && !part.contains('<')) return false;
  // EMAIL_MATCH_PATTERN needs an "@", and nothing below adds one.
  if (!part.contains('@')) return false;
  final parsed =
      _angleAddress.firstMatch(part)?.group(1) ??
      (_plainAddress.hasMatch(part) ? part : null);
  if (parsed == null) {
    // Quotes, comments, groups, routes or brackets: parseaddr's result here
    // is not reproduced, and differs between Python versions. Refuse only
    // what cannot pass on any of them; the server decides the rest.
    return _mayHoldAddress.hasMatch(part);
  }
  var emailId = parsed;
  if (!_checkFormat(parsed)) {
    final found = _emailString.firstMatch(part)?.group(1);
    if (found != null && _checkFormat(found)) emailId = found;
  }
  return _emailMatch.hasMatch(emailId);
}

/// `check_format`, counting code points as Python's `len` does.
bool _checkFormat(String email) {
  final cps = email.runes.toList();
  final at = cps.lastIndexOf(0x40);
  return at > 0 && cps.lastIndexOf(0x2E) > at && cps.length - at > 4;
}

/// `validate_url`: `urlparse(txt)` has a scheme and a host or path, or
/// [txt] starts with "/". `urlparse` runs first, and a bracket without its
/// partner in the host makes it raise, which fails the save as well.
bool _frappeAcceptsUrl(String txt) {
  // urlsplit drops leading C0 controls and spaces, and removes tabs and line
  // breaks anywhere.
  var start = 0;
  while (start < txt.length && txt.codeUnitAt(start) <= 0x20) {
    start++;
  }
  var url = txt.substring(start).replaceAll(_lineBreaks, '');

  var scheme = '';
  final colon = url.indexOf(':');
  if (colon > 0 &&
      _isAsciiLetter(url.codeUnitAt(0)) &&
      url.substring(0, colon).split('').every(_schemeChars.contains)) {
    scheme = url.substring(0, colon).toLowerCase();
    url = url.substring(colon + 1);
  }

  var netloc = '';
  if (url.startsWith('//')) {
    var end = url.length;
    for (final c in const ['/', '?', '#']) {
      final i = url.indexOf(c, 2);
      if (i >= 0 && i < end) end = i;
    }
    netloc = url.substring(2, end);
    url = url.substring(end);
    // ValueError("Invalid IPv6 URL"). A host with both brackets is checked
    // as an IPv6 literal only by newer Pythons, so it is left to the server.
    if (netloc.contains('[') != netloc.contains(']')) return false;
  }
  final hash = url.indexOf('#');
  if (hash >= 0) url = url.substring(0, hash);
  final query = url.indexOf('?');
  if (query >= 0) url = url.substring(0, query);
  // urlparse's `_splitparams`: the path ends at a ";" after its last "/".
  if (_usesParams.contains(scheme) && url.contains(';')) {
    final slash = url.lastIndexOf('/');
    final semi = slash >= 0 ? url.indexOf(';', slash) : url.indexOf(';');
    if (semi >= 0) url = url.substring(0, semi);
  }
  return (scheme.isNotEmpty && (netloc.isNotEmpty || url.isNotEmpty)) ||
      txt.startsWith('/');
}

bool _isAsciiLetter(int c) =>
    (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);
