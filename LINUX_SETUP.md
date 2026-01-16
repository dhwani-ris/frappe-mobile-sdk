# Linux Setup Instructions

## Required Dependencies

The package requires `libsecret-1-dev` for secure storage on Linux.

### Install Dependencies

```bash
sudo apt-get update
sudo apt-get install libsecret-1-dev
```

### For Ubuntu/Debian

```bash
sudo apt-get install libsecret-1-dev
```

### For Fedora/RHEL

```bash
sudo dnf install libsecret-devel
```

### For Arch Linux

```bash
sudo pacman -S libsecret
```

## After Installation

After installing the dependencies, rebuild the app:

```bash
cd frappe_mobile_sdk/example
flutter clean
flutter pub get
flutter run -d linux
```

## Alternative: Skip Secure Storage (Development Only)

If you can't install `libsecret-1-dev`, you can modify `auth_service.dart` to use a simple storage mechanism for development:

```dart
// For development only - not secure!
import 'package:shared_preferences/shared_preferences.dart';

class SimpleAuthStorage {
  static const String _keyBaseUrl = 'frappe_base_url';
  static const String _keyToken = 'frappe_token';
  
  Future<void> write(String key, String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, value);
  }
  
  Future<String?> read(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(key);
  }
  
  Future<void> delete(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(key);
  }
  
  Future<void> deleteAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
  }
}
```

**Note**: This is NOT secure and should only be used for development/testing.

## Troubleshooting

### Error: "libsecret-1>=0.18.4 not found"

**Solution**: Install `libsecret-1-dev` package as shown above.

### Error: "CMake not found"

**Solution**: Install CMake:
```bash
sudo apt-get install cmake
```

### Error: "pkg-config not found"

**Solution**: Install pkg-config:
```bash
sudo apt-get install pkg-config
```

## Verify Installation

Check if libsecret is installed:

```bash
pkg-config --modversion libsecret-1
```

Should output something like: `0.20.5`
