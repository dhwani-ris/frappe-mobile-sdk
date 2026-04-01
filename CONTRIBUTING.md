# Contributing to Frappe Mobile SDK

Thank you for your interest in this project. This document describes how to set up a development environment, run checks, and submit changes.

## Code of conduct

Participation is governed by our [Code of Conduct](CODE_OF_CONDUCT.md). By contributing, you agree to uphold it.

## What to contribute

- Bug fixes and regressions tests
- Documentation improvements (`README.md`, `doc/`, examples)
- Features that fit the scope of the SDK (Frappe integration, forms, offline/sync, auth)
- Test coverage and example app updates

For large or API-breaking changes, it helps to open an issue first to agree on direction.

## Development setup

1. **Prerequisites**
   - [Flutter](https://docs.flutter.dev/get-started/install) (stable channel recommended)
   - Dart SDK compatible with `environment.sdk` in [`pubspec.yaml`](pubspec.yaml) (currently `^3.10.4`)

2. **Clone and fetch dependencies**

   ```bash
   git clone https://github.com/dhwani-ris/frappe-mobile-sdk.git
   cd frappe-mobile-sdk
   flutter pub get
   ```

3. **Example app** (optional, for manual testing)

   ```bash
   cd example
   flutter pub get
   flutter run
   ```

## Quality checks before you push

Run the same checks CI runs:

```bash
dart format .
flutter analyze
flutter test
```

Pre-commit automation (recommended) is documented in [`.github/PRE_COMMIT.md`](.github/PRE_COMMIT.md), including:

- `dart run flutter_pre_commit` — format and analyze on staged Dart files
- Optional [pre-commit](https://pre-commit.com/) hooks from `.pre-commit-config.yaml`

## Commit messages

CI validates commit messages using [Conventional Commits](https://www.conventionalcommits.org/):

`type(scope)?: subject`

**Types:** `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`, `ci`, `build`, `perf`, `revert`

**Examples:**

- `fix: correct link field options when parent changes`
- `feat(auth): add session restore logging`
- `docs: clarify offline sync in DOCUMENTATION.md`

## Pull requests

1. Fork the repository and create a branch from `main` (or the target branch your PR should merge into).
2. Keep changes focused; avoid unrelated refactors in the same PR.
3. Update or add tests when behavior changes.
4. Ensure `dart format`, `flutter analyze`, and `flutter test` pass locally.
5. Describe **what** changed and **why** in the PR description. Link related issues when applicable.

Maintainers will review as time allows; feedback may request tests, docs, or smaller follow-up PRs.

## Documentation map

| Topic | Location |
|--------|----------|
| Full SDK API and concepts | [`doc/DOCUMENTATION.md`](doc/DOCUMENTATION.md) |
| Environment and platform setup | [`doc/SETUP.md`](doc/SETUP.md) |
| UI customization | [`doc/CUSTOMIZATION.md`](doc/CUSTOMIZATION.md) |
| Testing | [`doc/TESTING.md`](doc/TESTING.md) |
| Workflows | [`doc/WORKFLOWS.md`](doc/WORKFLOWS.md) |
| Pre-commit and CI details | [`.github/PRE_COMMIT.md`](.github/PRE_COMMIT.md) |

## Security

If you believe you have found a security vulnerability, please follow [SECURITY.md](SECURITY.md) instead of filing a public issue.

## License

By contributing, you agree that your contributions will be licensed under the same terms as the project — see [LICENSE](LICENSE).
