# Pre-commit and CI

CI is for **validating code**: analyze, format check, and tests. No build (APK) or publish.

| Workflow | When | What |
|----------|------|------|
| **CI** (`ci.yml`) | Push/PR to `main`, `master`, `develop` | `flutter analyze`, `dart format --set-exit-if-changed`, `flutter test` |
| **Semantic commit messages** (`semantic-commits.yml`) | Push/PR to `main`, `master`, `develop` | Validates commit messages follow Conventional Commits |

---

## Flutter pre-commit (recommended)

Uses [flutter_pre_commit](https://pub.dev/packages/flutter_pre_commit) to run format + analyze on staged Dart files before each commit.

1. Install (already in `dev_dependencies`):
   ```bash
   flutter pub get
   ```

2. Install the Git hook (runs automatically before `git commit`):
   ```bash
   dart run flutter_pre_commit
   ```
   This installs a hook that runs `dart format` and `flutter analyze` on staged files.

3. Commit as usual. To skip the hook (not recommended): `git commit --no-verify`.

## Pre-commit framework (optional)

If you use [pre-commit](https://pre-commit.com/) (Python):

1. Install: `pip install pre-commit`
2. Install hooks: `pre-commit install`
3. Run manually: `pre-commit run --all-files`

Hooks in `.pre-commit-config.yaml`: `dart format`, `flutter analyze`.

## Semantic commits (CI)

GitHub Actions validate commit messages on push/PR against [Conventional Commits](https://www.conventionalcommits.org/).

Format: **type(scope)?: subject**

- **Types:** `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`, `ci`, `build`, `perf`, `revert`
- **Scope:** optional, e.g. `feat(auth): add login`
- **Example:** `fix: correct link field options when parent changes`

Invalid commits will fail the "Semantic commit messages" workflow.
