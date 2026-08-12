# CLAUDE.md — frappe_mobile_sdk

This is a **public, MIT-licensed Flutter SDK** published to pub.dev and hosted on GitHub.
Every file you commit here is permanently public and indexed by search engines.

---

## CRITICAL: Commit Allowlist

**Only the following file types and paths may ever be staged or committed.**
Everything else is strictly forbidden — no exceptions, no "just this once."

```
lib/**/*.dart                     ← SDK source code only
test/**/*.dart                    ← test files only
doc/*.md                          ← PUBLIC end-user documentation only
doc/release-*/                    ← PUBLIC release notes only
example/lib/**/*.dart
example/test/**/*.dart
example/pubspec.yaml
example/analysis_options.yaml
example/README.md
android/src/main/kotlin/**/*.kt
android/build.gradle
android/src/main/AndroidManifest.xml
ios/frappe_mobile_sdk/Package.swift
ios/frappe_mobile_sdk/Sources/**/*.swift
ios/frappe_mobile_sdk.podspec
pubspec.yaml
analysis_options.yaml
CHANGELOG.md
README.md
LICENSE
CODE_OF_CONDUCT.md
CONTRIBUTING.md
SECURITY.md
logo.png
.gitignore
.releaserc
.eslintrc
.pre-commit-config.yaml
commitlint.config.js
.github/workflows/*.yml
.github/helper/*.py
.github/PRE_COMMIT.md
```

### Forbidden — NEVER commit these

| Pattern | Why |
|---------|-----|
| `doc/superpowers/**` | Private AI planning artifacts |
| `*_REVIEW.md` | Private review documents |
| `*_FIXES_CHECKLIST.md` | Private tracking files |
| `*_PLAN*.md` | Private implementation plans |
| `PLAN-*.md` | Private implementation plans |
| `docs/**` | Local scratch docs directory |
| `*.db`, `*.sqlite` | Database files |
| `*.env*` | Environment / secrets |
| `devtools_options.yaml` | Local dev tooling |
| `.mcp.json` | Local dev tooling |
| Any root-level `*.md` not in the allowlist above | Could be private |
| Any file outside `lib/`, `test/`, `doc/`, `example/`, `android/`, `ios/` | Treat as private unless explicitly in the allowlist |

---

## Before Every `git add`

Run this mental check:

1. **Is this file in the allowlist above?** If NO — do not add it.
2. **Does this file contain implementation plans, specs, design docs, review notes, or
   personal working notes?** If YES — do not add it regardless of path.
3. **Is this a `.dart` file outside `lib/` or `test/`?** Do not add it.
4. **Is this a `.md` file not already tracked in `git ls-files`?** Stop and verify
   it is a genuine public SDK doc before adding.

When in doubt, do NOT add the file. Ask the user first.

---

## What This SDK Is

A Flutter package for building offline-first mobile apps on top of a Frappe backend.

### Commands

```bash
# Run tests
flutter test

# Analyze
flutter analyze
dart format .

# Run tests in specific directory
flutter test test/sync/
flutter test test/ui/
```

### Architecture

```
lib/
├── frappe_mobile_sdk.dart        ← barrel export
└── src/
    ├── api/                      ← HTTP client, auth, doctype/document services
    ├── database/                 ← SQLite schema, DAOs, migrations
    │   ├── daos/                 ← per-table DAO classes
    │   └── schema/               ← DDL, system tables, column definitions
    ├── models/                   ← DocTypeMeta, DocField, SyncState, etc.
    ├── sdk/                      ← FrappeSDK top-level class + builders
    ├── security/                 ← FrappeSecurityService (root/mock-GPS detection)
    ├── services/                 ← TranslationService, PermissionService, etc.
    ├── sync/                     ← PullEngine, PushEngine, PullApply, SyncController
    ├── ui/                       ← FrappeFormBuilder + all field widgets
    └── utils/                    ← date_helpers, sdk_log, translate, etc.
```

### Key Invariants

- **`lib/`** — only `.dart` files. No JSON, no YAML, no generated files except `.dart`.
- **`test/`** — mirrors `lib/src/` structure. Use `sqflite_common_ffi` for in-memory DB tests.
- **`doc/`** — only PUBLIC end-user docs that ship as part of the package on pub.dev.
  `doc/superpowers/` is gitignored and must NEVER appear in `git status` as staged.
- **No `Co-Authored-By:` trailers** in any commit message.
- **No `debugPrint`** in SDK source — use `sdkLog` from `utils/sdk_log.dart`.
- **No `dart:io` direct file access** in `lib/` — use abstractions.

### Commit Style

```
type(scope): short description

# Types: feat | fix | test | docs | chore | perf | refactor
# Scope: sync | ui | api | database | sdk | security | translations | utils | attachments
```

Examples:
```
fix(sync): guard bulk path against server_name=NULL rows
feat(ui): add required validation for multi-select fields
test(translations): add clearAll generation race test
chore(utils): remove dead parseTime function
```
