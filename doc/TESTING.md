# Testing

This file is the primary reference for testing the SDK.

## Local checks (same as CI basics)

Run from the repository root:

```bash
dart format .
flutter analyze
flutter test
```

## Publishing check

Before publishing to pub.dev:

```bash
dart pub publish --dry-run
```

