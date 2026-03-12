# Frappe Workflows in the Mobile SDK

> Start here: see the high‑level overview and navigation in `README.md`. This document explains how workflows behave in the mobile SDK in detail.

The SDK supports **Frappe workflows** for DocTypes that have a workflow attached. Behavior matches **Frappe core**: workflow action buttons appear in the **App Bar** only when the form has **no unsaved changes**; when there are changes, the **Save** button is shown instead. Submitted documents (`docstatus == 1`) are **read-only**.

## When workflow actions are shown

- The DocType has a workflow attached (detected from meta `__workflow_docs`).
- The form is opened for an **existing** document (has a server name / `serverId`).
- The screen is used with **API (online)** mode: `FormScreen` is given a non-null `api` (`FrappeClient`).
- The form has **no unsaved changes** (same as loaded/saved data). If the user edits any field, **Save** is shown and workflow actions are hidden until the form is saved or reverted.

Workflow actions are **not** shown for new (unsaved) documents or when offline.

## Frappe-like App Bar behavior

- **Unsaved changes** → App bar shows **Save** (and Delete if allowed). Workflow action buttons are hidden.
- **No unsaved changes and workflow exists** → App bar shows **workflow action buttons** (e.g. Approve, Reject) instead of Save. Save is hidden until the user edits the form.
- **New document** → App bar shows **Save** only (no workflow until the document is saved).

So: **Save** when the form is dirty; **workflow actions** when the form is clean and the DocType has a workflow.

## Submitted documents are read-only

If the document has **docstatus == 1** (Submitted), the form is **read-only**: fields cannot be edited, matching Frappe’s behavior. Save and workflow actions still apply (workflow can change state; Save is irrelevant if no edits are allowed).

## How it works (no server changes)

1. **Meta** – When the SDK loads DocType meta via `getdoctype`, Frappe includes `__workflow_docs` when the DocType has an active workflow. The SDK uses this to know:
   - Whether the DocType has a workflow (`DocTypeMeta.hasWorkflow`).
   - Which field stores the state (`DocTypeMeta.workflowStateField`).
2. **Transitions** – The SDK calls the whitelisted method `frappe.model.workflow.get_transitions` with `{ doctype, name }` to get the list of allowed transitions for the current document and user.
3. **Apply** – When the user taps an action, the SDK calls `frappe.model.workflow.apply_workflow` with `{ doc: { doctype, name }, action }`. Frappe updates the document and returns the updated doc; the SDK updates the local repository and refreshes the form.

## API surface

### DocTypeMeta

- **`bool get hasWorkflow`** – `true` if the DocType has an active workflow (from `__workflow_docs`).
- **`String? get workflowStateField`** – The field that stores workflow state (e.g. `workflow_state`). Non-null only when `hasWorkflow` is true.

### WorkflowService

- **`WorkflowService(FrappeClient client)`**
- **`Future<List<WorkflowTransition>> getTransitions(String doctype, String docname)`** – Returns allowed transitions for the document.
- **`Future<Map<String, dynamic>> applyWorkflow(String doctype, String docname, String action)`** – Applies the given workflow action and returns the updated document.

### WorkflowTransition

- **`String action`** – Label to show and to pass to `applyWorkflow` (e.g. `"Approve"`).
- **`String nextState`** – Next state after this transition.
- **`String state`** – Current state for this transition.
- **`String? allowed`** – Role required for this transition.
- **`bool allowSelfApproval`** – Whether the document owner can perform this transition.

## Using workflow programmatically

If you need to drive workflow from your own UI or logic:

```dart
final client = FrappeClient(baseUrl, ...);
final workflow = WorkflowService(client);

// Get allowed actions for a document
final transitions = await workflow.getTransitions('Leave Application', 'LEAVE-2024-001');

// Apply an action
final updated = await workflow.applyWorkflow('Leave Application', 'LEAVE-2024-001', 'Approve');
// Use updated to refresh your document data.
```

## FormScreen behavior

- **With workflow** – If `meta.hasWorkflow` is true, the document exists, and `api != null`, `FormScreen` loads allowed transitions and shows **workflow action buttons in the App Bar** when the form has no unsaved changes. It creates a `WorkflowService` from `api`; on action press it calls `applyWorkflow`, updates the repository and baseline data, then refreshes the list of transitions. When the user edits the form, the App Bar switches to **Save** until the form is saved again.

## Requirements

- Frappe server with workflow configured on the DocType (Workflow document linked to the DocType, workflow state field set).
- No extra server-side code: the SDK uses `frappe.model.workflow.get_transitions` and `frappe.model.workflow.apply_workflow`, which are whitelisted in Frappe core.
