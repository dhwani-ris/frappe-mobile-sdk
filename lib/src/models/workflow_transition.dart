/// Represents a possible Frappe workflow transition for the current document state.
/// Returned by [WorkflowService.getTransitions].
class WorkflowTransition {
  /// Action label (e.g. "Approve", "Reject"). Use for button label and when calling apply.
  final String action;

  /// Next state name after this transition.
  final String nextState;

  /// Current state name (state from which this transition is allowed).
  final String state;

  /// Role required to perform this transition.
  final String? allowed;

  /// Whether the document owner can perform this transition.
  final bool allowSelfApproval;

  const WorkflowTransition({
    required this.action,
    required this.nextState,
    required this.state,
    this.allowed,
    this.allowSelfApproval = false,
  });

  factory WorkflowTransition.fromJson(Map<String, dynamic> json) {
    final allow = json['allow_self_approval'];
    return WorkflowTransition(
      action: json['action'] as String? ?? '',
      nextState: json['next_state'] as String? ?? '',
      state: json['state'] as String? ?? '',
      allowed: json['allowed'] as String?,
      allowSelfApproval: allow == 1 || allow == true,
    );
  }
}
