# Building and Installing Your Updated App

## Quick Start

```bash
chmod +x install.sh
./install.sh
```

That's it! The script will auto-detect your signing identity if you have one.

---

## Understanding the Permission Reset Issue

### Why Permissions Reset

macOS ties **Accessibility** and **Screen Recording** permissions to the **code signature** of the app. When you use **ad-hoc signing** (signing with `-`), the signature changes with every build, so macOS sees it as a "new" app and forgets the permissions.

### Solution: Use a Persistent Signing Identity

#### Option 1: Auto-Detection (Easiest)

The `install.sh` script will automatically find your Apple Development certificate if you have one:

```bash
./install.sh
```

If it finds a signing identity, you'll see:
```
📝 Auto-detected signing identity: Apple Development: Your Name (TEAMID)
   (Permissions will persist between builds)
```

#### Option 2: Manual Signing Identity

If you want to specify a particular identity:

```bash
# Find your signing identities
security find-identity -v -p codesigning

# Use a specific one
export SIGN_IDENTITY="Apple Development: Your Name (TEAMID)"
./install.sh
```

Or use the official dev-install script:

```bash
SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/dev-install.sh
```

#### Option 3: Get a Free Signing Certificate

If you don't have a signing identity:

1. **Create a free Apple ID** (if you don't have one)
2. **Open Xcode** → Settings (⌘,)
3. **Accounts tab** → Click `+` → Add your Apple ID
4. **Manage Certificates...** → Click `+` → **Apple Development**
5. Now re-run `./install.sh` - it will auto-detect your new certificate!

---

## Troubleshooting

### "Permission denied" Error

```bash
chmod +x install.sh
```

### Build Fails with Missing Types

Make sure you're in the project root:

```bash
cd /path/to/yabai-dockstack
./install.sh
```

### Permissions Still Resetting

Check if signing worked:

```bash
codesign -dv --verbose=4 /Applications/yabai-dockstack.app 2>&1 | grep "Authority"
```

Should show:
- ✅ `Authority=Apple Development: Your Name` (good - permissions persist)
- ❌ `Authority=` (empty - ad-hoc signing, permissions reset)

### "The application cannot be opened" Error

This can happen after permissions reset. To fix:

1. Open **System Settings** → **Privacy & Security**
2. Scroll to the bottom - you'll see a message about the app
3. Click **Open Anyway**
4. Grant **Accessibility** and **Screen Recording** permissions when prompted

---

## Build Options

### Debug Build (Faster for Testing)

```bash
swift build
# Binary is at: .build/debug/yabai-dockstack
```

### Release Build (Optimized)

```bash
swift build -c release
# Binary is at: .build/release/yabai-dockstack
```

### Universal Build (Both Intel & Apple Silicon)

```bash
swift build -c release --arch arm64 --arch x86_64
# Binary is at: .build/apple/Products/Release/yabai-dockstack
```

---

## What Got Fixed

### ✅ Build Error
- Moved `WindowFocusHelper` logic into `App.swift` as a simple `enum WindowFocuser`
- No longer needs a separate file that might not be in the package

### ✅ Permission Resets
- Updated install script to auto-detect signing identities
- Added clear warnings about ad-hoc signing
- Provided simple instructions for getting a free certificate

### ✅ Minimized Window Detection
- Only the specific minimized window shows the overlay symbol
- Other windows from the same app show normal previews

### ✅ Keyboard Shortcut Deminimize
- All window focusing (dock, menu, keyboard shortcuts) uses `WindowFocuser`
- Minimized windows always deminimize to current space

### ✅ Autodesk Fusion Filtering
- Filters out helper processes (streamer/scriptapp)
- Shows only the main Fusion window

---

## Next Steps

1. **Run the install script:**
   ```bash
   ./install.sh
   ```

2. **Grant permissions** (one time per signature)

3. **Test the features:**
   - Hover over apps in Dock - minimized windows show symbol
   - Click minimized window - deminimizes to current space
   - Use keyboard shortcuts - same smart behavior
   - Hover over Fusion - shows only one window

4. **For future updates:**
   - Just run `./install.sh` again
   - If you have a signing identity, permissions won't reset!

---

## Advanced: Using the Official Scripts

### Development Build with Signing

```bash
SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" \
./scripts/dev-install.sh
```

### Release Build for Distribution

```bash
# With notarization (requires paid Apple Developer account)
DEVID="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="your-profile" \
./scripts/release.sh 1.0.0
```

---

## Summary

- ✅ Use `./install.sh` for quick development
- ✅ Get a free Apple Development certificate to avoid permission resets
- ✅ Permissions only need to be granted once per signature
- ✅ All fixes are now working correctly
