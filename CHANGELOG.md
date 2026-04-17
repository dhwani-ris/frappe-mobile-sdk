# [1.1.0](https://github.com/dhwani-ris/frappe-mobile-sdk/compare/v1.0.0...v1.1.0) (2026-04-17)


### Bug Fixes

* **auth:** disable social login and auto-discovery ([4382822](https://github.com/dhwani-ris/frappe-mobile-sdk/commit/43828221e73e119c986a6329aa53473eb6964060))
* **review:** move docs to doc/FIELD_TYPES.md, remove pubspec.lock from tracking ([72f7c74](https://github.com/dhwani-ris/frappe-mobile-sdk/commit/72f7c745af60272f1df5a390d0be6366a470f39b))


### Features

* add optional field change handler and improve form data handling ([9012b3e](https://github.com/dhwani-ris/frappe-mobile-sdk/commit/9012b3e1ee02386472793ef8ad07c28387ad4b0e))
* **auth:** implement social login support with OAuth integration ([e123df7](https://github.com/dhwani-ris/frappe-mobile-sdk/commit/e123df7809f806825bf9554087adec24ba616890))
* **fields:** add SearchableSelect, TableMultiSelect, Geolocation field widgets and fix form data handling ([06e8a32](https://github.com/dhwani-ris/frappe-mobile-sdk/commit/06e8a327dc0590c9d8d6c0c797104d6540c695a0))

# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-04-01

### Added

- Initial stable release of **Frappe Mobile SDK** for Flutter (`frappe_mobile_sdk`).
- **Frappe API client** — authentication (password, OAuth, API key, mobile OTP), CRUD, file upload, custom methods, and query-style access via `FrappeClient`.
- **Stateless mobile auth** — `mobile_auth.login` integration with token persistence, session restore, and automatic token refresh.
- **Dynamic forms** — metadata-driven rendering from Frappe DocTypes (`FrappeFormBuilder`, list and document screens).
- **Offline-first data layer** — SQLite storage, offline repository, and bi-directional sync with conflict handling.
- **App guard** — `FrappeAppGuard` for server-driven app status, versioning, and force-update flows (requires [Frappe Mobile Control](https://github.com/dhwani-ris/frappe_mobile_control) on the server).
- **Translations** — load dictionaries from the server and apply to labels in forms and lists.
- **Workflows** — workflow state and transitions on forms when configured on the DocType.
- Example app under `example/` and in-repo docs under `doc/`.

[1.0.0]: https://github.com/dhwani-ris/frappe-mobile-sdk/releases/tag/v1.0.0
