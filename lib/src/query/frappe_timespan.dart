/// Resolves Frappe-style timespan keywords (e.g. `today`, `this month`,
/// `last 7 days`) into an absolute `[start, end]` ISO range. Mirror of
/// Frappe's `frappe/utils/data.py:get_timespan_date_range`. Spec §6.4.
///
/// `now` is injectable so tests can pin "now" to a fixed instant; when
/// omitted, `DateTime.now().toUtc()` is used.
class TimespanRange {
  /// Inclusive lower bound, formatted `YYYY-MM-DD HH:MM:SS` (UTC).
  final String start;

  /// Inclusive upper bound, same format. End-of-day for date-only ranges.
  final String end;

  const TimespanRange({required this.start, required this.end});
}

typedef ClockFn = DateTime Function();

class FrappeTimespan {
  static TimespanRange resolve(
    String keyword, {
    ClockFn now = _defaultNow,
  }) {
    final n = now();
    final lk = keyword.toLowerCase().trim();

    final lastNDays = RegExp(r'^last (\d+) days$').firstMatch(lk);
    if (lastNDays != null) {
      final days = int.parse(lastNDays.group(1)!);
      final start = _startOfDay(n.subtract(Duration(days: days)));
      final end = _endOfDay(n);
      return TimespanRange(start: _iso(start), end: _iso(end));
    }

    switch (lk) {
      case 'today':
        return _range(_startOfDay(n), _endOfDay(n));
      case 'yesterday':
        final y = n.subtract(const Duration(days: 1));
        return _range(_startOfDay(y), _endOfDay(y));
      case 'tomorrow':
        final t = n.add(const Duration(days: 1));
        return _range(_startOfDay(t), _endOfDay(t));
      case 'this week':
        final mon = _mondayOf(n);
        final sun = mon.add(const Duration(days: 6));
        return _range(_startOfDay(mon), _endOfDay(sun));
      case 'last week':
        final mon = _mondayOf(n).subtract(const Duration(days: 7));
        final sun = mon.add(const Duration(days: 6));
        return _range(_startOfDay(mon), _endOfDay(sun));
      case 'next week':
        final mon = _mondayOf(n).add(const Duration(days: 7));
        final sun = mon.add(const Duration(days: 6));
        return _range(_startOfDay(mon), _endOfDay(sun));
      case 'this month':
        final first = DateTime.utc(n.year, n.month, 1);
        final next = DateTime.utc(n.year, n.month + 1, 1);
        final last = next.subtract(const Duration(days: 1));
        return _range(_startOfDay(first), _endOfDay(last));
      case 'last month':
        final first = DateTime.utc(n.year, n.month - 1, 1);
        final next = DateTime.utc(n.year, n.month, 1);
        final last = next.subtract(const Duration(days: 1));
        return _range(_startOfDay(first), _endOfDay(last));
      case 'next month':
        final first = DateTime.utc(n.year, n.month + 1, 1);
        final next = DateTime.utc(n.year, n.month + 2, 1);
        final last = next.subtract(const Duration(days: 1));
        return _range(_startOfDay(first), _endOfDay(last));
      case 'this quarter':
        return _quarterRange(n);
      case 'last quarter':
        return _quarterRange(DateTime.utc(n.year, n.month - 3, n.day));
      case 'next quarter':
        return _quarterRange(DateTime.utc(n.year, n.month + 3, n.day));
      case 'this year':
        return _range(
          DateTime.utc(n.year, 1, 1),
          _endOfDay(DateTime.utc(n.year, 12, 31)),
        );
      case 'last year':
        return _range(
          DateTime.utc(n.year - 1, 1, 1),
          _endOfDay(DateTime.utc(n.year - 1, 12, 31)),
        );
      case 'next year':
        return _range(
          DateTime.utc(n.year + 1, 1, 1),
          _endOfDay(DateTime.utc(n.year + 1, 12, 31)),
        );
    }
    throw ArgumentError.value(keyword, 'timespan', 'unknown');
  }

  static DateTime _defaultNow() => DateTime.now().toUtc();

  static DateTime _startOfDay(DateTime d) =>
      DateTime.utc(d.year, d.month, d.day, 0, 0, 0);

  static DateTime _endOfDay(DateTime d) =>
      DateTime.utc(d.year, d.month, d.day, 23, 59, 59);

  static DateTime _mondayOf(DateTime d) {
    final wd = d.weekday; // 1 = Monday
    return _startOfDay(d.subtract(Duration(days: wd - 1)));
  }

  static TimespanRange _range(DateTime start, DateTime end) =>
      TimespanRange(start: _iso(start), end: _iso(end));

  static TimespanRange _quarterRange(DateTime d) {
    final q = ((d.month - 1) ~/ 3);
    final firstMonth = q * 3 + 1;
    final first = DateTime.utc(d.year, firstMonth, 1);
    final nextQ = DateTime.utc(d.year, firstMonth + 3, 1);
    final last = nextQ.subtract(const Duration(days: 1));
    return _range(_startOfDay(first), _endOfDay(last));
  }

  static String _iso(DateTime d) =>
      '${d.year.toString().padLeft(4, "0")}-'
      '${d.month.toString().padLeft(2, "0")}-'
      '${d.day.toString().padLeft(2, "0")} '
      '${d.hour.toString().padLeft(2, "0")}:'
      '${d.minute.toString().padLeft(2, "0")}:'
      '${d.second.toString().padLeft(2, "0")}';
}
