import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// QA #313 — the same month appeared several times in Sowing / Harvesting /
/// Processing Season. A Table MultiSelect is a SET on the web side; Frappe's
/// own control cannot hold the same link twice. Mobile could: the parent may
/// re-emit an already-selected value and a server payload can carry repeats.
///
/// HONEST SCOPE (corrected 2026-09-04): `TableMultiSelectField._selected` is
/// private `State`, so this file cannot execute it. An earlier version of this
/// test re-implemented the rule locally and asserted against its own copy —
/// reverting the widget left it green, which made it worse than no test.
///
/// What this pins is the SHAPE of the rule against the real row payloads the
/// widget receives. It is a specification test, NOT a regression guard on the
/// widget: only a widget test pumping TableMultiSelectField can be that, and
/// the parity of the two is asserted by `_ruleSourceMatchesWidget` below.
List<String> selectionOf(List<dynamic> rows, String linkField) {
  final seen = <String>{};
  final out = <String>[];
  for (final r in rows.whereType<Map<String, dynamic>>()) {
    final v = r[linkField]?.toString() ?? '';
    if (v.isEmpty) continue;
    if (seen.add(v)) out.add(v);
  }
  return out;
}

void main() {
  group('Table MultiSelect selection rule (QA #313)', () {
    test('collapses a repeated month to one entry', () {
      final rows = [
        {'month': 'February'},
        {'month': 'June'},
        {'month': 'February'},
      ];
      expect(selectionOf(rows, 'month'), ['February', 'June']);
    });

    test('keeps first-occurrence order', () {
      final rows = [
        {'month': 'December'},
        {'month': 'April'},
        {'month': 'December'},
        {'month': 'April'},
      ];
      expect(selectionOf(rows, 'month'), ['December', 'April']);
    });

    test('drops empty and non-map rows without losing the rest', () {
      final rows = <dynamic>[
        {'month': ''},
        'garbage',
        {'month': 'May'},
        {'other': 'x'},
      ];
      expect(selectionOf(rows, 'month'), ['May']);
    });

    test('the widget still implements this rule (source parity)', () {
      // The teeth this file would otherwise lack: if someone reverts
      // `_selected` back to the un-deduplicated map/where/toList, this fails.
      final src = File('lib/src/ui/widgets/fields/table_multi_select_field.dart')
          .readAsStringSync();
      final sel = src.substring(src.indexOf('List<String> get _selected'));
      final body = sel.substring(0, sel.indexOf('\n  }'));
      expect(body.contains('seen.add'), isTrue,
          reason: '_selected must de-duplicate; see QA #313');
      expect(body.contains('.map(') && body.contains('.toList()'), isFalse,
          reason: 'the old non-deduplicating map/toList form is back');
    });

    test('an already-unique list is returned unchanged', () {
      final rows = [
        {'month': 'Jan'},
        {'month': 'Feb'},
      ];
      expect(selectionOf(rows, 'month'), ['Jan', 'Feb']);
    });
  });
}
