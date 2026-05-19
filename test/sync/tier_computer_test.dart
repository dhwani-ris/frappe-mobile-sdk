import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/sync/tier_computer.dart';
import 'package:frappe_mobile_sdk/src/models/outbox_row.dart';

OutboxRow row(
  int id,
  String doctype,
  String uuid,
  OutboxOperation op, {
  String? payload,
}) =>
    OutboxRow(
      id: id,
      doctype: doctype,
      mobileUuid: uuid,
      operation: op,
      payload: payload,
      state: OutboxState.pending,
      retryCount: 0,
      createdAt: DateTime.utc(2026, 1, id),
    );

void main() {
  test('no cross-row deps → everything in tier 0', () {
    final rows = [
      row(1, 'A', 'u1', OutboxOperation.insert),
      row(2, 'B', 'u2', OutboxOperation.insert),
    ];
    final tiers = TierComputer.compute(
      rows: rows,
      dependenciesForRow: (r) => const [],
    );
    expect(tiers.length, 1);
    expect(tiers.first.length, 2);
  });

  test('row 2 depends on row 1 → two tiers', () {
    final rows = [
      row(1, 'A', 'u1', OutboxOperation.insert),
      row(2, 'B', 'u2', OutboxOperation.insert),
    ];
    final tiers = TierComputer.compute(
      rows: rows,
      dependenciesForRow: (r) => r.id == 2 ? const ['u1'] : const [],
    );
    expect(tiers.length, 2);
    expect(tiers[0].first.id, 1);
    expect(tiers[1].first.id, 2);
  });

  test('cycles fall through to a final tier (no infinite loop)', () {
    final rows = [
      row(1, 'A', 'u1', OutboxOperation.insert),
      row(2, 'B', 'u2', OutboxOperation.insert),
    ];
    // u1 depends on u2 and u2 depends on u1 — must not hang.
    final tiers = TierComputer.compute(
      rows: rows,
      dependenciesForRow: (r) => r.id == 1 ? const ['u2'] : const ['u1'],
    );
    final all = tiers.expand((t) => t).toList();
    expect(all.length, 2,
        reason:
            'cycle survivors must be emitted, not lost — engine then handles them');
  });

  test('dependency on a mobile_uuid NOT in pending set → tier 0', () {
    final rows = [row(1, 'A', 'u1', OutboxOperation.insert)];
    final tiers = TierComputer.compute(
      rows: rows,
      dependenciesForRow: (r) => const ['not-in-pending-set'],
    );
    expect(tiers.length, 1);
    expect(tiers.first.first.id, 1);
  });

  test('preserves created_at order within a tier', () {
    final rows = [
      row(2, 'A', 'u2', OutboxOperation.insert),
      row(1, 'A', 'u1', OutboxOperation.insert),
    ];
    final tiers = TierComputer.compute(
      rows: rows,
      dependenciesForRow: (r) => const [],
    );
    expect(tiers.first.map((r) => r.id).toList(), [1, 2]);
  });

  test('row depending on itself is treated as no dep (avoids self-cycle)', () {
    final rows = [row(1, 'A', 'u1', OutboxOperation.insert)];
    final tiers = TierComputer.compute(
      rows: rows,
      dependenciesForRow: (r) => const ['u1'],
    );
    expect(tiers.length, 1);
    expect(tiers.first.first.id, 1);
  });
}
