# Frappe Mobile SDK

Offline-first Flutter package for Frappe/ERPNext integration with dynamic form rendering and bi-directional sync.

## 📋 Table of Contents

- [Features](#features)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Documentation](#documentation)
- [Architecture](#architecture)
- [Field Types Supported](#field-types-supported)
- [UI Customization](#ui-customization)
- [Contributing](#contributing)
- [License](#license)
- [Credits](#credits)

## ✨ Features

- ✅ **Offline-First Architecture** - Full offline capability with SQLite (Floor)
- ✅ **Dynamic Form Rendering** - Auto-generate forms from Frappe metadata
- ✅ **Bi-directional Sync** - Push/pull sync with conflict resolution
- ✅ **Token-based Auth** - Secure authentication with token storage
- ✅ **Material 3 UI** - Modern, customizable UI components
- ✅ **Sync Status Screen** - View sync errors and pending changes

## 🚀 Installation

Add this to your `pubspec.yaml`:

```yaml
dependencies:
  frappe_mobile_sdk:
    git:
      url: https://github.com/your-repo/frappe_mobile_sdk.git
      ref: main
```

Or if published to pub.dev:

```yaml
dependencies:
  frappe_mobile_sdk: ^1.0.0
```

Then run:

```bash
flutter pub get
```

## 📖 Quick Start

### 1. Initialize Database

```dart
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';

final database = await AppDatabase.getInstance();
```

### 2. Setup Authentication

```dart
final authService = AuthService(client);
await authService.login(username: 'user', password: 'pass');
```

### 3. Load Metadata

```dart
final metaService = MetaService(client, database);
final meta = await metaService.getMeta('State');
```

### 4. Render Form

```dart
FrappeFormBuilder(
  meta: meta,
  initialData: document?.data,
  onSubmit: (formData) async {
    // Save document
  },
)
```

## 📚 Documentation

- **[SETUP.md](SETUP.md)** - Detailed setup instructions and configuration
- **[CUSTOMIZATION.md](CUSTOMIZATION.md)** - UI customization guide with examples
- **[TESTING.md](TESTING.md)** - Testing strategies and examples
- **[QUICK_TEST.md](QUICK_TEST.md)** - Quick testing guide for developers
- **[LINUX_DEPENDENCIES.md](LINUX_DEPENDENCIES.md)** - Linux system dependencies and setup

## 🏗️ Architecture

```
┌─────────────────────────────────────────┐
│ Flutter App                             │
├─────────────────────────────────────────┤
│ UI Layer (Material 3)                  │
│ ├── Login Screen                        │
│ ├── DocType List                        │
│ ├── Document List                       │
│ ├── Form Screen                         │
│ └── Sync Status Screen                  │
├─────────────────────────────────────────┤
│ Services Layer                          │
│ ├── AuthService                         │
│ ├── MetaService                         │
│ ├── SyncService                         │
│ ├── OfflineRepository                  │
│ └── LinkOptionService                   │
├─────────────────────────────────────────┤
│ Data Layer (SQLite via Floor)          │
│ ├── Documents                           │
│ ├── DocType Meta                        │
│ └── Link Options                        │
└─────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────┐
│ Frappe/ERPNext Server                   │
└─────────────────────────────────────────┘
```

## 🎨 Field Types Supported

- **Data** - Text input
- **Text/Long Text** - Multi-line text areas
- **Select** - Dropdown selection
- **Date** - Date picker
- **Check** - Checkbox/Boolean
- **Float/Currency/Int/Percent** - Numeric inputs
- **Link** - Link fields with option caching
- **Phone** - Phone number with country code selector

## 🎨 UI Customization

The package provides extensive customization options:

- **Form-level styling** via `FrappeFormStyle`
- **Field-level styling** via `FieldStyle`
- **Custom field factories** for complete control
- **Extensible base classes** for custom fields

See [CUSTOMIZATION.md](CUSTOMIZATION.md) for detailed examples.

## 🤝 Contributing

Contributions are welcome! Please read our contributing guidelines before submitting PRs.

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🙏 Credits

### Third-Party Packages

This package uses the following open-source packages:

- **[erpnext_sdk_flutter](https://pub.dev/packages/erpnext_sdk_flutter)** - ERPNext API client
- **[floor](https://pub.dev/packages/floor)** - SQLite database ORM
- **[sqflite](https://pub.dev/packages/sqflite)** - SQLite plugin for Flutter
- **[flutter_form_builder](https://pub.dev/packages/flutter_form_builder)** - Form building utilities
- **[provider](https://pub.dev/packages/provider)** - State management
- **[connectivity_plus](https://pub.dev/packages/connectivity_plus)** - Network connectivity checking
- **[flutter_secure_storage](https://pub.dev/packages/flutter_secure_storage)** - Secure token storage
- **[json_annotation](https://pub.dev/packages/json_annotation)** - JSON serialization
- **[uuid](https://pub.dev/packages/uuid)** - UUID generation
- **[intl](https://pub.dev/packages/intl)** - Internationalization

---

**Copyright (c) 2026 Dhwani Rural Information System**
