import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/workflow_transition.dart';

void main() {
  test('fromJson maps all fields including int allow_self_approval', () {
    final t = WorkflowTransition.fromJson({
      'action': 'Approve',
      'next_state': 'Approved',
      'state': 'Pending',
      'allowed': 'Manager',
      'allow_self_approval': 1,
    });
    expect(t.action, 'Approve');
    expect(t.nextState, 'Approved');
    expect(t.state, 'Pending');
    expect(t.allowed, 'Manager');
    expect(t.allowSelfApproval, isTrue);
  });

  test('fromJson maps bool allow_self_approval=true', () {
    final t = WorkflowTransition.fromJson({
      'action': 'Reject',
      'next_state': 'Rejected',
      'state': 'Pending',
      'allow_self_approval': true,
    });
    expect(t.allowSelfApproval, isTrue);
  });

  test('fromJson defaults: empty strings and allowSelfApproval=false', () {
    final t = WorkflowTransition.fromJson({});
    expect(t.action, '');
    expect(t.nextState, '');
    expect(t.state, '');
    expect(t.allowed, isNull);
    expect(t.allowSelfApproval, isFalse);
  });

  test('fromJson allow_self_approval=0 yields false', () {
    final t = WorkflowTransition.fromJson({
      'action': 'Submit',
      'next_state': 'Submitted',
      'state': 'Draft',
      'allow_self_approval': 0,
    });
    expect(t.allowSelfApproval, isFalse);
  });
}
