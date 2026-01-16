# Setup Instructions

## 1. Install Dependencies

```bash
cd frappe_mobile_sdk
flutter pub get
```

## 2. Generate Code

Run build_runner to generate Floor database code and JSON serialization:

```bash
flutter pub run build_runner build --delete-conflicting-outputs
```

This will generate:
- `lib/src/database/app_database.g.dart` - Floor database code
- `lib/src/models/*.g.dart` - JSON serialization code

## 3. Configure App Config

Create an `app_config.json` file in your app:

```json
{
  "base_url": "https://your-frappe-site.com",
  "doctypes": ["Lead", "Customer", "Item"]
}
```

Or create it programmatically:

```dart
final appConfig = AppConfig(
  baseUrl: 'https://your-frappe-site.com',
  doctypes: ['Lead', 'Customer', 'Item'],
);
```

## 4. Android Setup

Add to `android/app/build.gradle`:

```gradle
android {
    defaultConfig {
        minSdkVersion 21
    }
}
```

## 5. iOS Setup

Add to `ios/Podfile`:

```ruby
platform :ios, '12.0'
```

## 6. Usage Example

See `example/lib/main.dart` for a complete example.

## Troubleshooting

### Floor Generation Issues

If you get errors during code generation:

1. Clean build:
```bash
flutter clean
flutter pub get
flutter pub run build_runner clean
flutter pub run build_runner build --delete-conflicting-outputs
```

2. Check that all imports are correct
3. Ensure all models have proper annotations

### Database Issues

If you get database errors:

1. Delete the app and reinstall (clears database)
2. Check database version matches in `app_database.dart`
3. Ensure migrations are properly defined if you change schema

### Sync Issues

If sync fails:

1. Check internet connectivity
2. Verify authentication token is valid
3. Check server logs for API errors
4. Ensure doctypes are properly configured
