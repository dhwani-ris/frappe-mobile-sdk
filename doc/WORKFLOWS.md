# Workflows

This file documents how workflows are surfaced in the SDK UI and points to the SDK classes involved.

## How workflows are detected

- Workflows are detected from DocType metadata (see `DocTypeMeta.hasWorkflow` and `DocTypeMeta.workflowStateField`).
- Transitions/actions are fetched and applied via `WorkflowService`.

## How workflows appear in the UI (`FormScreen`)

`FormScreen` behaves like a Frappe-style form:

- **Unsaved changes**: shows **Save** (and **Delete** if allowed)
- **Clean form + workflow present**: shows workflow action buttons instead of Save
- **New document**: shows Save; workflow actions only after the first save
- **Submitted documents** (`docstatus == 1`): treated as read-only

## Related code

- `lib/src/models/doc_type_meta.dart`
- `lib/src/services/workflow_service.dart`
- `lib/src/ui/form_screen.dart`

