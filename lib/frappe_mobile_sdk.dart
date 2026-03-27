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

// Utils (debug tracer + user-friendly errors)
export 'src/api/utils.dart' show extractErrorMessage, toUserFriendlyMessage;
export 'src/utils/api_tracer.dart' show ApiTracer;
