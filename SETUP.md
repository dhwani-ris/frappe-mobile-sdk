# Setup Instructions

## 1. Install Dependencies

```bash
cd frappe_mobile_sdk
flutter pub get
```

## 2. Configure App Config

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

## 3. Android Setup

Add to `android/app/build.gradle`:

```gradle
android {
    defaultConfig {
        minSdkVersion 21
    }
}
```

## 4. iOS Setup

Add to `ios/Podfile`:

```ruby
platform :ios, '12.0'
```

## 5. Usage Example

See `example/lib/main.dart` for a complete example.

## Troubleshooting

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
