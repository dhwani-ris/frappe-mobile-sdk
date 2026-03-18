// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// For license information, please see license.txt

import '../api/client.dart';
import '../models/workflow_transition.dart';

/// Service for Frappe workflow actions. Uses whitelisted methods
/// [frappe.model.workflow.get_transitions] and [frappe.model.workflow.apply_workflow].
class WorkflowService {
  final FrappeClient _client;

  WorkflowService(this._client);

  /// Fetches allowed workflow transitions for the given document.
  /// Returns empty list if doctype has no workflow, doc is new, or user has no transitions.
  Future<List<WorkflowTransition>> getTransitions(
    String doctype,
    String docname,
  ) async {
    final result = await _client.call(
      'frappe.model.workflow.get_transitions',
      args: {
        'doc': {'doctype': doctype, 'name': docname},
      },
    );

    if (result == null) return [];

    // Frappe may return a bare list OR wrap it in a {"message": [...]} or {"docs": [...]} map.
    dynamic rawList = result;
    if (rawList is Map<String, dynamic>) {
      if (rawList['message'] is List) {
        rawList = rawList['message'];
      } else if (rawList['docs'] is List) {
        rawList = rawList['docs'];
      }
    }

    if (rawList is! List) return [];

    final list = <WorkflowTransition>[];
    for (final e in rawList) {
      if (e is Map<String, dynamic>) {
        list.add(WorkflowTransition.fromJson(e));
      }
    }
    return list;
  }

  /// Applies a workflow transition (e.g. "Approve", "Reject").
  /// Returns the updated document as returned by Frappe (use to refresh form data).
  Future<Map<String, dynamic>> applyWorkflow(
    String doctype,
    String docname,
    String action,
  ) async {
    final result = await _client.call(
      'frappe.model.workflow.apply_workflow',
      args: {
        'doc': {'doctype': doctype, 'name': docname},
        'action': action,
      },
    );
    if (result is Map<String, dynamic>) return result;
    if (result != null && result is! Map<String, dynamic>) {
      return {'name': docname};
    }
    return {'name': docname};
  }
}
