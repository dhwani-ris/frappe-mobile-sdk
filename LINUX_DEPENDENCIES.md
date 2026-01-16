# Linux Dependencies

## Required System Packages

For the Frappe Mobile SDK to work on Linux, you need to install:

### 1. SQLite Development Library

```bash
sudo apt-get install libsqlite3-dev
```

### 2. Secure Storage Library (libsecret)

```bash
sudo apt-get install libsecret-1-dev
```

### 3. Build Tools (if not already installed)

```bash
sudo apt-get install build-essential
```

## Complete Installation Command

```bash
sudo apt-get update
sudo apt-get install -y libsqlite3-dev libsecret-1-dev build-essential
```

## Verify Installation

Check if libraries are installed:

```bash
# Check SQLite
pkg-config --modversion sqlite3

# Check libsecret
pkg-config --modversion libsecret-1

# Check linker
which ld
```

## After Installation

Rebuild the app:

```bash
cd frappe_mobile_sdk/example
flutter clean
flutter pub get
flutter run -d linux
```

## Troubleshooting

### Error: "libsqlite3.so: cannot open shared object file"

**Solution**: Install `libsqlite3-dev`
```bash
sudo apt-get install libsqlite3-dev
```

### Error: "libsecret-1>=0.18.4 not found"

**Solution**: Install `libsecret-1-dev`
```bash
sudo apt-get install libsecret-1-dev
```

### Error: "Failed to find ld.lld"

**Solution**: Install build tools
```bash
sudo apt-get install build-essential
```

## Alternative: Docker Development

If you prefer not to install system packages, you can use Docker:

```dockerfile
FROM ubuntu:24.04
RUN apt-get update && \
    apt-get install -y \
    libsqlite3-dev \
    libsecret-1-dev \
    build-essential \
    curl
# ... rest of your Dockerfile
```
