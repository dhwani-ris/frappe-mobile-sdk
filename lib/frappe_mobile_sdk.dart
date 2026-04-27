/// Frappe Mobile SDK - Production-ready Flutter package for Frappe
///
/// This package provides:
/// - Direct Frappe API access (Auth, CRUD, file upload)
/// - Dynamic form rendering using Frappe metadata
/// - Offline-first architecture with SQLite
/// - Bi-directional sync engine
/// - Generic storage (no table per DocType)
library frappe_mobile_sdk;

// Core models
export 'src/models/app_config.dart';
export 'src/models/doc_type_meta.dart';
export 'src/models/doc_field.dart';
export 'src/models/document.dart';
export 'src/models/mobile_form_name.dart';
export 'src/models/workflow_transition.dart';
export 'src/models/link_filter_result.dart';

// Database
export 'src/database/app_database.dart';
export 'src/database/entities/doctype_meta_entity.dart';
export 'src/database/entities/document_entity.dart';
export 'src/database/daos/doctype_meta_dao.dart';
export 'src/database/daos/document_dao.dart';

// API Client (Direct Frappe API Access)
export 'src/api/client.dart' show FrappeClient;
export 'src/api/doctype_service.dart' show DoctypeService;
export 'src/api/document_service.dart' show DocumentService;
export 'src/api/attachment_service.dart' show AttachmentService;
export 'src/api/exceptions.dart'
    show
        FrappeException,
        AuthException,
        ApiException,
        NetworkException,
        ValidationException;
export 'src/api/frappe_document.dart' show FrappeDocument;
export 'src/api/query_builder.dart' show QueryBuilder;
export 'src/api/oauth2_helper.dart'
    show OAuth2Helper, OAuth2TokenResponse, PkcePair;

// SDK Initialization (Easy Setup)
export 'src/sdk/frappe_sdk.dart';

// Services
export 'src/services/auth_service.dart';
export 'src/services/app_status_service.dart';
export 'src/services/meta_service.dart';
export 'src/services/permission_service.dart';
export 'src/services/translation_service.dart';
export 'src/services/sync_service.dart';
export 'src/services/offline_repository.dart';
export 'src/services/link_option_service.dart';
export 'src/services/link_field_coordinator.dart';
export 'src/services/workflow_service.dart';

// Screens
export 'src/screens/mobile_home_screen.dart';

// UI Components
export 'src/ui/app_guard.dart';
export 'src/ui/login_screen.dart';
export 'src/ui/login_screen_style.dart';
export 'src/ui/doctype_list_screen.dart';
export 'src/ui/form_screen.dart';
export 'src/ui/document_list_screen.dart';
export 'src/ui/sync_status_screen.dart';
export 'src/ui/form_renderer_helper.dart';
export 'src/ui/widgets/form_builder.dart'; // Exports FrappeFormStyle, ButtonPressedCallback, OnButtonPressedCallback
export 'src/ui/widgets/default_form_style.dart'; // Exports DefaultFormStyle
export 'src/ui/widgets/fields/field_factory.dart';
export 'src/ui/widgets/fields/base_field.dart'; // Exports FieldStyle
export 'src/ui/widgets/fields/data_field.dart';
export 'src/ui/widgets/fields/text_field.dart';
export 'src/ui/widgets/fields/select_field.dart';
export 'src/ui/widgets/fields/date_field.dart';
export 'src/ui/widgets/fields/check_field.dart';
export 'src/ui/widgets/fields/button_field.dart';
export 'src/ui/widgets/fields/numeric_field.dart';
export 'src/ui/widgets/fields/link_field.dart';
export 'src/ui/widgets/fields/phone_field.dart';

// Constants
export 'src/constants/field_types.dart';
export 'src/constants/oauth_constants.dart';

// Query (UnifiedResolver + FilterParser) — Spec §6
export 'src/query/filter_errors.dart'
    show FilterParseError, UnsupportedFilterError;
export 'src/query/filter_parser.dart' show FilterParser;
export 'src/query/frappe_timespan.dart' show FrappeTimespan, TimespanRange;
export 'src/query/link_decorator.dart' show LinkDecorator, TargetMetaResolver;
export 'src/query/parsed_query.dart' show ParsedQuery;
export 'src/query/query_result.dart' show QueryResult, RowOrigin;
export 'src/query/unified_resolver.dart'
    show UnifiedResolver, BackgroundFetcher, IsOnlineFn;

// UI surface + lifecycle (P6) — Spec §6.6, §7.x, §9.3
export 'src/models/session_user.dart' show SessionUser;
export 'src/services/atomic_wipe.dart' show AtomicWipe, OnCreateFn;
export 'src/services/retry_priority.dart' show RetryPriority;
export 'src/services/session_user_service.dart' show SessionUserService;
export 'src/services/sync_controller.dart'
    show SyncController, ConflictAction, DeleteCascadePlan, RunFn;
export 'src/sync/sync_state.dart'
    show SyncState, DoctypeSyncState, QueueSummary, SyncErrorSummary;
export 'src/sync/sync_state_notifier.dart' show SyncStateNotifier;
export 'src/ui/widgets/sync_status_bar.dart' show SyncStatusBar;
export 'src/ui/widgets/document_list_filter_chip.dart'
    show DocumentListFilterChip, DocumentListFilter, DocumentListFilterCounts;
export 'src/ui/widgets/delete_cascade_prompt.dart'
    show showDeleteCascadePrompt, DeleteCascadeAction;
export 'src/ui/screens/migration_blocked_screen.dart'
    show MigrationBlockedScreen;
export 'src/ui/screens/sync_errors_screen.dart' show SyncErrorsScreen;
export 'src/ui/screens/sync_progress_screen.dart' show SyncProgressScreen;
export 'src/ui/dialogs/logout_guard_dialog.dart'
    show showLogoutGuardDialog, LogoutGuardAction;
export 'src/ui/dialogs/force_logout_confirm.dart'
    show showForceLogoutConfirm;

// Utils (debug tracer + user-friendly errors)
export 'src/api/utils.dart' show extractErrorMessage, toUserFriendlyMessage;
export 'src/utils/api_tracer.dart' show ApiTracer;
