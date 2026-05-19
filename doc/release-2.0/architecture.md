# Architecture — `frappe_mobile_sdk` 2.0

This document is the visual map of how 2.0 fits together. Every claim is grounded in code. Cites use `file::symbolName` form (durable across refactors); line numbers appear only when pointing into the middle of a method body.

Diagrams use [Mermaid](https://mermaid.js.org/) — GitHub, GitLab, and pub.dev render them inline.

---

## 1. Service dependency graph

`FrappeSDK` is the top-level façade. On `initialize()` it builds the service graph in dependency order, wires the read and write paths, and exposes the resulting components as fields.

```mermaid
graph TD
    SDK[FrappeSDK] --> AppDB[(AppDatabase<br/>schema v3)]
    SDK --> Auth[AuthService]
    Auth -->|owns| Client[FrappeClient<br/>REST]
    SDK --> Meta[MetaService]
    SDK --> OfflineMode[OfflineModeNotifier]
    SDK --> OfflineRepo[OfflineRepository]
    SDK --> SyncSvc[SyncService]
    SDK --> Resolver[UnifiedResolver]
    SDK --> LinkOpts[LinkOptionService]
    SDK --> SessionUser[SessionUserService]
    SDK --> Transition[OfflineTransitionService]
    SDK --> PermSvc[PermissionService]
    SDK --> TransSvc[TranslationService]

    PermSvc --> AppDB
    PermSvc --> Client
    TransSvc --> Client

    OfflineRepo --> AppDB
    OfflineRepo --> Client
    OfflineRepo --> OfflineMode

    SyncSvc --> Client
    SyncSvc --> OfflineRepo
    SyncSvc --> AppDB
    SyncSvc --> OfflineMode

    Resolver --> AppDB
    Resolver --> Client
    Resolver --> OfflineMode

    LinkOpts --> Resolver
    LinkOpts --> Meta

    Meta --> AppDB
    Meta --> Client
```

- `FrappeSDK` is defined at `lib/src/sdk/frappe_sdk.dart::FrappeSDK`.
- All services accept an `OfflineModeNotifier` and short-circuit to REST passthroughs when `offline_enabled = false`. See [Offline-mode lifecycle](#8-offline-mode-lifecycle).
- The sync sub-engines — `PushEngine` (`lib/src/sync/push_engine.dart`), `PullEngine` (`lib/src/sync/pull_engine.dart`), `SyncController` (`lib/src/services/sync_controller.dart`) — are built by `SyncEngineBuilder.build()` and owned directly by `FrappeSDK` as private fields. `SyncService` calls them via function injection (`pushRunner`, `pullRunner`). Omitted from the graph to reduce visual noise; their internal flows are in sections 5 and 6.

---

## 2. Init flow

`FrappeSDK.initialize([autoRestoreAndSync])` is the production entrypoint. A one-shot lock prevents concurrent initialization.

```mermaid
sequenceDiagram
    participant App as Consumer App
    participant SDK as FrappeSDK
    participant DB as AppDatabase
    participant Auth as AuthService
    participant Sync as SyncService
    participant Resolver as UnifiedResolver
    participant LOS as LinkOptionService
    participant Trans as OfflineTransition

    App->>SDK: initialize(autoRestoreAndSync: true)
    SDK->>DB: getInstance() — open or migrate
    DB-->>SDK: AppDatabase (schema v3)
    SDK->>Auth: init(baseUrl, db)
    Auth-->>SDK: FrappeClient (Bearer / API-key)
    SDK->>DB: read sdk_meta.offline_enabled
    DB-->>SDK: persisted flag
    SDK->>SDK: _resolveBootMode() — flag or residue check
    SDK->>SDK: build OfflineModeNotifier, MetaService,<br/>OfflineRepository, PermissionService,<br/>TranslationService
    SDK->>SDK: SyncEngineBuilder.build() →<br/>PushEngine, PullEngine, SyncController
    SDK->>Sync: build(client, repo, db, getMobileUuid, offlineMode)
    SDK->>SDK: probe connectivity (cache _cachedOnline)
    SDK->>Resolver: build(client, offlineMode, isOnline)
    SDK->>LOS: build(resolver, metaResolver)
    SDK->>Trans: build(drainFactory)
    SDK->>SDK: SessionUserService — restore from sdk_meta
    SDK->>SDK: _initialized = true

    alt autoRestoreAndSync == true
        SDK->>Auth: restoreSession()
        Auth-->>SDK: success / failure
        opt has offline residue
            SDK--)Trans: queue runDrainAndWipe() (background)
        end
        SDK->>SDK: _initialMetaAndDataSync()
        Note right of SDK: permissions → translations →<br/>checkAndSyncDoctypes →<br/>resyncMobileConfiguration →<br/>closure pull
    end
    SDK-->>App: ready
```

- Public entry: `lib/src/sdk/frappe_sdk.dart::initialize` (one-shot lock around `_doInitialize`).
- The internal builder: `lib/src/sdk/frappe_sdk.dart::_doInitialize`.
- Post-restore bootstrap: `lib/src/sdk/frappe_sdk.dart::_initialMetaAndDataSync` runs permissions → translations → `MetaService.checkAndSyncDoctypes` → `MetaService.resyncMobileConfiguration` → closure pull. Each step logs its own failures and does not rethrow. Closure pull only runs in offline mode (gated by `_offlineMode.enabled`).

For testing, `lib/src/sdk/frappe_sdk.dart::FrappeSDK.forTesting` wires the same graph synchronously without `FlutterSecureStorage` and without async connectivity probes.

---

## 3. Storage layers

The single SQLite file holds three logical layers. Two of them are touched on every write; the third holds engine state.

```mermaid
graph LR
    subgraph "AppDatabase (schema v3)"
        direction LR
        subgraph "Per-doctype mirror (lazy)"
            P1[docs__Customer]
            P2[docs__Sales_Invoice]
            P3[docs__Sales_Invoice_Item<br/>parent_uuid → docs__Sales_Invoice]
        end
        subgraph "System tables (eager)"
            SM[(sdk_meta<br/>singleton)]
            OB[(outbox)]
            PA[(pending_attachments)]
            DM[(doctype_meta)]
            AT[(auth_tokens)]
            DP[(doctype_permission)]
        end
        subgraph "Legacy"
            DOC[(documents<br/>DROPPED in v3)]
        end
    end
    P3 -.parent ref.-> P2
    OB -.targets.-> P1
    OB -.targets.-> P2
    PA -.targets.-> P1
```

| Layer | Tables | Created where | Purpose |
|---|---|---|---|
| Per-doctype mirror | `docs__<doctype>` (parent or child schema) | Lazily — first pull for that doctype, via `lib/src/services/offline_repository.dart::OfflineRepository.ensureSchemaForClosure`. | Native columnar offline store. Read path (`UnifiedResolver`) queries this. Children carry `parent_uuid`. |
| System | `sdk_meta`, `outbox`, `pending_attachments`, `doctype_meta`, `auth_tokens`, `doctype_permission` | Eagerly — `lib/src/database/app_database.dart::_onCreate` on fresh install; `lib/src/database/app_database.dart::_migrateV2ToV3` on upgrade. | Engine state: schema version, push queue, attachment queue, meta cache, tokens, permissions. |
| Legacy | `documents` | Dropped inside `_migrateV2ToV3` (`DROP TABLE IF EXISTS documents`). | Removed in 2.0 — see [Schema migration](schema-migration.md). |

Schema invariants:

- `mobile_uuid` is the PRIMARY KEY on every parent `docs__*` table.
- `server_name` is `UNIQUE WHERE server_name IS NOT NULL`, enforcing single-identity for synced rows.
- A row's identity transitions from `(mobile_uuid)` to `(mobile_uuid, server_name)` on first successful push.

---

## 4. Read path — `UnifiedResolver`

All list reads (list screens, Link pickers, `fetch_from`) flow through one resolver.

```mermaid
flowchart TD
    Caller[Caller<br/>list screen / Link picker / fetch_from] --> R[UnifiedResolver.resolve]
    R --> Q1{offline mode<br/>enabled?}
    Q1 -->|no| Online[Online passthrough<br/>FrappeClient.doctype.list]
    Q1 -->|yes| MetaResolve[Resolve DocTypeMeta]
    MetaResolve --> TableName["Get table name<br/>docs__&lt;doctype&gt;"]
    TableName --> Q2{is child<br/>doctype?}
    Q2 -->|yes| TranslateParent["Translate 'parent' filter →<br/>'parent_uuid' via server_name lookup"]
    Q2 -->|no| InjectStatus["Inject sync_status NOT IN ('failed')<br/>unless includeFailed"]
    TranslateParent --> InjectStatus
    InjectStatus --> Parse["FilterParser.toSql →<br/>bound params, whitelisted columns"]
    Parse --> RawQuery[(db.rawQuery)]
    RawQuery --> Decorate["LinkDecorator —<br/>add display companions"]
    Decorate --> Return["QueryResult with RowOrigin<br/>(returned to caller)"]
    Decorate -.fire-and-forget if online and stale.-> Background["BackgroundFetcher —<br/>refreshes local store<br/>(does not block Return)"]
    Online --> Return
```

- Resolver entrypoint: `lib/src/query/unified_resolver.dart::UnifiedResolver.resolve`.
- Filter parsing: `lib/src/query/filter_parser.dart::FilterParser` — pure function, no DB or I/O.
- Background refresh: `lib/src/query/unified_resolver.dart::BackgroundFetcher` typedef; the fire-and-forget call is wired by `FrappeSDK._doInitialize` to delegate to `SyncService.pullSyncWaiting`.
- Behavior change: `pullSync` skips child doctypes (`istable=1`) via `lib/src/services/sync_service.dart::_isChildTable` invoked at the top of `_pullOneInternal` — children come embedded in parent pulls.

For details on Link decoration and `fetch_from`, see [`doc/OFFLINE_FIRST.md`](../OFFLINE_FIRST.md#read-path-unifiedresolver).

---

## 5. Push pipeline — tier-ordered outbox dispatch

The push engine drains the outbox in dependency-aware tiers.

```mermaid
flowchart LR
    Outbox[(outbox<br/>state: pending)] --> Tiers[TierComputer.compute]
    Tiers --> T0[Tier 0<br/>no upstream deps]
    Tiers --> T1[Tier 1<br/>deps in tier 0]
    Tiers --> Tn["Tier k<br/>deps in tiers below k"]
    T0 --> Pool[Concurrent<br/>worker pool]
    T1 -.after T0.-> Pool
    Tn -.after Tk-1.-> Pool
    PendingAttach[(pending_attachments)] -.read/write.-> Attach
    Pool --> Attach["AttachmentPipeline<br/>uploadPendingForTopParent"]
    Attach -->|upload ok| Inline["inlinePayload<br/>pending:id → file_url"]
    Attach -->|upload failed| Failed
    Inline --> Push["FrappeClient POST / PUT / DELETE<br/>(L1 is a server-side property:<br/>autoname=field:mobile_uuid makes Frappe<br/>reject duplicate INSERTs natively)"]
    Push --> Resp{Server<br/>response}
    Resp -->|2xx| Reconcile["ResponseWriteback —<br/>update server_name + modified;<br/>write child server names;<br/>delete outbox row"]
    Resp -->|"DuplicateEntryError (INSERT)"| L2["L2: _resolveDuplicate —<br/>fetch existing by name from<br/>exception body or by mobile_uuid"]
    L2 -->|fetched| Reconcile
    L2 -->|fallback unavailable| Failed["markFailed /<br/>markConflict /<br/>markBlocked"]
    Resp -->|TimestampMismatchError| AutoMerge["_autoMergeAndRetry —<br/>ThreeWayMerge + retry once"]
    AutoMerge -->|merged + retry ok| Reconcile
    AutoMerge -->|no server_name or retry failed| Failed
    Resp -->|network failure| Retry{"retry<br/>budget left?"}
    Retry -->|yes, INSERT retry| L3["L3: pre-retry GET<br/>by mobile_uuid<br/>(detects prior 2xx we missed)"]
    L3 -->|found on server| Reconcile
    L3 -->|not found| Push
    Retry -->|no| Failed
    Resp -->|validation / permission| Failed
    Reconcile --> Done([sync_status: synced])
```

- Push entry: `lib/src/sync/push_engine.dart::PushEngine.runOnce`.
- Attachment upload: `lib/src/sync/attachment_pipeline.dart::AttachmentPipeline.uploadPendingForTopParent` — runs before payload assembly; resolves `pending:<id>` markers via `inlinePayload`; exhausted retries throw `BlockedByUpstream` → `markBlocked`.
- Tiering: `lib/src/sync/tier_computer.dart::TierComputer.compute`. Tier 0 has no inter-pending dependencies; tier `k` depends only on tiers `< k`. Stable order within a tier: `createdAt asc, id asc`.
- Idempotency on INSERT lives in `lib/src/sync/push_engine.dart::PushEngine._dispatchOnce`. L1 is a server-side property (`autoname=field:mobile_uuid` makes Frappe reject duplicates by `name == mobile_uuid`); only L2 and L3 are SDK code paths — L2 is `PushEngine._resolveDuplicate` against the `DuplicateEntryError` body; L3 is the pre-retry GET-by-`mobile_uuid` inside `_dispatchOnce`.
- Reconcile (2xx success): `lib/src/sync/response_writeback.dart::ResponseWriteback.apply` (or `applyInTxn` inside a `WriteQueue` transaction). Updates `server_name`, `modified`, `sync_status` on the parent row; writes child server names; deletes the outbox row — all in one transaction.
- TimestampMismatchError path: `lib/src/sync/push_engine.dart::PushEngine._autoMergeAndRetry` — fetches the fresh server snapshot, calls `ThreeWayMerge.mergeFields` against the stored `push_base_payload`, persists merged values, retries `_dispatchOnce` once. Exhausted or no `server_name` → `markConflict`.

---

## 6. Pull pipeline — cursor-based delta

Each doctype maintains a `(modified, name)` watermark cursor with a phase tag.

```mermaid
stateDiagram-v2
    [*] --> initial: first pull (no cursor)
    initial --> resume: pull interrupted, cursor saved complete=false
    initial --> incremental: lookahead empty on first run, cursor complete=true
    resume --> resume: next page applied, still not final
    resume --> incremental: final page, cursor complete=true
    incremental --> incremental: subsequent pulls, modified >= cursor
```

For each page:

```mermaid
flowchart TD
    Trigger[Pull trigger] --> Guard{istable=1?}
    Guard -->|yes| Skip["Return SyncResult.empty —<br/>no list endpoint;<br/>children arrive via parent"]
    Guard -->|no| DocType{has child<br/>tables?}
    DocType -->|yes| PageFull["fire listFullDocs(start)<br/>modified >= cursor;<br/>orderBy: modified asc, name asc"]
    DocType -->|no| PageList["fire frappe.client.list(start)<br/>modified >= cursor;<br/>orderBy: modified asc, name asc"]
    PageFull --> Await[await page data]
    PageList --> Await
    Await --> Lookahead{page full?}
    Lookahead -->|yes| Fire["fire fetchPage(start+pageSize)<br/>in background"]
    Lookahead -->|no| Skip2[skip lookahead]
    Fire --> Row
    Skip2 --> Row[For each row in page]
    Row --> Tie{row ≤ cursor<br/>tie-skip}
    Tie -->|skip| Next
    Tie -->|keep| Apply["applyServerDocument →<br/>PullApply.applyPageInTxn"]
    Apply -->|ok| Conflict{existing local row<br/>is dirty/failed/conflict<br/>AND server modified is later?}
    Apply -->|throws| ApplyErr["log SyncError<br/>failed++, continue"]
    Conflict -->|yes| Mark["sync_status = conflict;<br/>preserve local payload"]
    Conflict -->|no| Write["Write parent row to<br/>docs__&lt;doctype&gt;"]
    Write --> Children["Children: 3-key match<br/>server_name → mobile_uuid → idx"]
    Mark --> Next[Next row]
    ApplyErr --> Next
    Children --> Next
    Next --> MoreRows{more rows<br/>in page?}
    MoreRows -->|yes| Row
    MoreRows -->|no| Persist["Persist cursor<br/>complete = isFinalPage"]
    Persist --> MorePages{lookahead<br/>returned data?}
    MorePages -->|yes| Await
    MorePages -->|no| Done["complete: true →<br/>incremental phase"]
```

Key cites in this pipeline:

- Pull entry: `lib/src/services/sync_service.dart::SyncService._pullOneInternal`.
- API selection: `listFullDocs` is used when the doctype has any `Table` / `Table MultiSelect` fields (children must arrive embedded); `frappe.client.list` is used for flat doctypes. Resolved once at the start of each `_pullOneInternal` call via `_repository.doctypesWithChildren()` + `_doctypeHasChildTables()`.
- Server-side filter (`modified >= cursorModified`) is built inside `_pullOneInternal`'s `filters` construction.
- Client-side tie-skip is row-level inside the page loop (handles same-second collisions where the cursor's tie group spans pages): the check compares `(row.modified, row.name)` against `(cursorModified, cursorName)` and skips strictly-≤ rows.
- Child guard: `lib/src/services/sync_service.dart::SyncService._isChildTable`, invoked at the top of `_pullOneInternal`.
- Final-page detection: `isFinalPage = lookahead == null` — lookahead is fired only when the current page came back full (`page.length >= pageSize`).
- Conflict detection: `lib/src/sync/pull_apply.dart::PullApply.applyPageInTxn` — fires `sync_status = 'conflict'` only when the existing row is in `dirty / failed / conflict / blocked` AND incoming `modified` strictly post-dates stored `modified`.
- Per-row error handling: `applyServerDocument` is called inside a `try/catch`. On unexpected failure (DB error, parse error), the row is logged as a `SyncError`, `failed` is incremented, and the loop continues to the next row without updating the cursor for that row.

For deeper detail (closure pull, attachments), see [`doc/OFFLINE_FIRST.md → Pull Lifecycle`](../OFFLINE_FIRST.md#pull-lifecycle).

---

## 7. Mobile UUID round-trip

When a locally-created doc is pushed for the first time, identity must transition from `(mobile_uuid)` to `(mobile_uuid, server_name)` without breaking inbound Link references.

```mermaid
sequenceDiagram
    participant Form as FormScreen
    participant Repo as OfflineRepository
    participant Outbox as outbox
    participant Push as PushEngine
    participant Server as Frappe server

    Form->>Repo: create(doc, mobile_uuid?)
    Repo->>Repo: stamp mobile_uuid (v4) if missing
    Repo->>Outbox: enqueue INSERT (op, doctype, mobile_uuid)
    Repo-->>Form: localId == mobile_uuid

    Push->>Outbox: pop pending row (Tier 0)
    Push->>Server: POST /api/method/...<br/>(mobile_uuid in payload)
    Server-->>Push: 200 { name: "CRM-CUST-2026-..." }

    Push->>Push: ResponseWriteback.apply(row, parentTable, childTables, response)
    Note right of Push: docs__Customer.server_name = response.name.<br/>sync_status = synced. outbox row deleted.
```

- Push reconcile: `lib/src/sync/response_writeback.dart::ResponseWriteback.apply` / `applyInTxn` (via WriteQueue). Updates `server_name`, `modified`, `sync_status = synced`; writes child server names; deletes the outbox row in a single transaction.
- `lib/src/services/offline_repository.dart::reconcileServerSave` is a **separate path** used by `FormScreen` for server-first (online) saves — it calls `LocalWriter.markSynced` + `OutboxDao.cancelPendingFor` + `applyServerDocument`. It is not called by `PushEngine`.

**Link references that already pointed at the row** (via local `mobile_uuid`) are rewritten to `server_name` on **their** push, by `lib/src/sync/uuid_rewriter.dart::UuidRewriter.rewrite`. Each Link column has an `<field>__is_local` companion flag (`= 1` until reconciled).

---

## 8. Offline-mode lifecycle

The session-bound offline mode is resolved at boot and can flip mid-session via the server flag.

```mermaid
stateDiagram-v2
    [*] --> Boot: app launch
    Boot --> ResolveMode: read sdk_meta.offline_enabled + check residue
    ResolveMode --> Online: flag = false and no residue
    ResolveMode --> Offline: flag = true or residue exists

    Online --> CheckFlag: login response carries offline_enabled
    Offline --> CheckFlag: login response carries offline_enabled

    CheckFlag --> Online: server says false, app was Online (no change)
    CheckFlag --> Offline: server says true (persist, no migration)
    CheckFlag --> Draining: server says false, app was Offline (start transition)

    Draining --> DrainFailed: any row failed
    Draining --> WipingTables: all drained
    DrainFailed --> Draining: user retry
    DrainFailed --> Online: forceExit (data loss)
    WipingTables --> Completed: docs__*, outbox, pending_attachments dropped
    Completed --> Online
```

- Boot resolution: `lib/src/sdk/frappe_sdk.dart::_resolveBootMode`.
- Transition states: `lib/src/services/offline_transition_service.dart::OfflineTransitionState` (sealed hierarchy: `TransitionIdle`, `TransitionDraining`, `TransitionDrainFailed`, `TransitionWipingTables`, `TransitionCompleted`).
- Drain + wipe: `lib/src/services/offline_transition_service.dart::OfflineTransitionService.runDrainAndWipe`.
- UI surface: wrap your app with `lib/src/ui/offline_transition_guard.dart::OfflineTransitionGuard`; it overlays `OfflineTransitionScreen` while transition is non-idle.

For server-side configuration of `offline_enabled`, see [`doc/OFFLINE_MODE_TOGGLE.md`](../OFFLINE_MODE_TOGGLE.md).

---

## 9. Form pipeline — render → change → cascade → link picker

When the user edits a Link field with dependent siblings, multiple subsystems coordinate.

```mermaid
sequenceDiagram
    participant Meta as DocTypeMeta
    participant FS as FormScreen
    participant FB as FrappeFormBuilder
    participant FF as FieldFactory
    participant LF as LinkField
    participant LOS as LinkOptionService
    participant UR as UnifiedResolver

    Meta->>FS: pass meta to FormScreen
    FS->>FB: pass meta to builder
    FB->>FF: createField(field, ...) per field
    FF->>LF: instantiate Link field<br/>(linkedDoctype = field.options)

    Note over LF,LOS: User taps Link field
    LF->>LOS: resolveFilters(field, rowData,<br/>hook: getLinkFilterBuilder?.call(target, fieldname))

    alt LinkFilterBuilder hook returns filters
        LOS-->>LF: dynamic filters
    else hook returns null
        LOS->>LOS: parse field.linkFilters JSON,<br/>evaluate eval:doc.x against rowData
        LOS-->>LF: static filters
    end

    LF->>LOS: getLinkOptions(linkedDoctype, filters)
    LOS->>UR: resolve(linkedDoctype, filters, ...)
    UR-->>LOS: rows from docs__{linkedDoctype}
    LOS-->>LF: LinkOptionEntity list

    Note over LF,FB: User selects an option
    LF->>FB: onChanged(value)
    FB->>FB: scan meta.fields for Link fields<br/>whose linkFilters contain<br/>eval:doc.{this.fieldname}<br/>→ clear those values
    FB->>FB: invoke optional FieldChangeHandler<br/>(value-derivation only)
    FB->>FB: merge patch into _formData
```

- Form construction: `lib/src/ui/widgets/form_builder.dart::FrappeFormBuilder`.
- Field dispatch: `lib/src/ui/widgets/fields/field_factory.dart::FieldFactory.createField`.
- Cascade clears (form-level): inside `_FrappeFormBuilderState`'s per-field `onChanged` — when `oldValue != value`, it walks `widget.meta.fields` and removes any `Link` field whose `linkFilters` regex matches `eval\s*:\s*doc.{thisFieldname}`.
- `LinkFilterBuilder` callsite: inside `lib/src/ui/widgets/fields/link_field.dart::_LinkFieldState`, the hook is invoked as `widget.getLinkFilterBuilder?.call(targetDoctype, fieldname)`. **Keyed on the target doctype** (`field.options`), not the owning field's name.
- Filter resolution helper: `lib/src/services/link_option_service.dart::LinkOptionService.parseLinkFilters`.

For `LinkFilterBuilder` patterns and examples, see [`doc/LINK_FILTER_BUILDER.md`](../LINK_FILTER_BUILDER.md).

---

## See also

- [whats-new.md](whats-new.md) — feature inventory with code samples.
- [breaking-changes.md](breaking-changes.md) — what to fix in your app.
- [schema-migration.md](schema-migration.md) — v2→v3 step-by-step with diagrams.
