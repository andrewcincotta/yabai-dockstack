#!/usr/bin/env bash
# Quick install for development - handles signing intelligently
set -euo pipefail

cd "$(dirname "$0")"

APP_PATH="/Applications/yabai-dockstack.app"
EXECUTABLE_NAME="yabai-dockstack"

# Auto-detect signing identity if not set
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    # Try to find an Apple Development identity
    FOUND_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | \
        grep "Apple Development" | head -1 | sed 's/.*"\(.*\)".*/\1/' || true)
    
    if [[ -n "$FOUND_IDENTITY" ]]; then
        echo "📝 Auto-detected signing identity: $FOUND_IDENTITY"
        echo "   (Permissions will persist between builds)"
        echo ""
        SIGN_IDENTITY="$FOUND_IDENTITY"
    else
        echo "⚠️  No signing identity found - using ad-hoc signing"
        echo "   (Permissions will reset after each build)"
        echo ""
        echo "   To enable persistent signing:"
        echo "   1. Get a free Apple Developer account"
        echo "   2. In Xcode: Settings → Accounts → Add your Apple ID"
        echo "   3. Create a certificate if needed"
        echo ""
    fi
fi

echo "🔨 Building release version..."
swift build -c release

BUILD_DIRECTORY=".build/release"
BUILT_EXECUTABLE="$BUILD_DIRECTORY/$EXECUTABLE_NAME"

if [[ ! -x "$BUILT_EXECUTABLE" ]]; then
    echo "❌ Error: built executable not found at $BUILT_EXECUTABLE" >&2
    exit 1
fi

echo "🛑 Stopping the current app..."
pkill -x "$EXECUTABLE_NAME" 2>/dev/null || true
sleep 1

echo "📦 Updating $APP_PATH..."
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp scripts/Info.plist.template "$APP_PATH/Contents/Info.plist"
[[ ! -f assets/AppIcon.icns ]] || cp assets/AppIcon.icns "$APP_PATH/Contents/Resources/AppIcon.icns"
[[ ! -f assets/menubar.png ]] || cp assets/menubar.png "$APP_PATH/Contents/Resources/menubar.png"

# Copy executable
EXECUTABLE_TEMP="$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME.new"
cp "$BUILT_EXECUTABLE" "$EXECUTABLE_TEMP"
chmod +x "$EXECUTABLE_TEMP"
mv -f "$EXECUTABLE_TEMP" "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"

# Copy resource bundles
for bundle in "$BUILD_DIRECTORY"/*YabaiDockstackKit.bundle; do
    [[ -d "$bundle" ]] || continue
    RESOURCE_DESTINATION="$APP_PATH/Contents/Resources/$(basename "$bundle")"
    rm -rf "$RESOURCE_DESTINATION"
    ditto "$bundle" "$RESOURCE_DESTINATION"
done

# Sign
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    echo "✍️  Signing with: $SIGN_IDENTITY"
    codesign --force --deep --sign "$SIGN_IDENTITY" \
        --identifier com.yabai-dockstack.agent \
        "$APP_PATH"
    codesign --verify --deep --strict "$APP_PATH" 2>/dev/null && \
        echo "✅ Signature verified - permissions will persist"
else
    echo "✍️  Ad-hoc signing..."
    codesign --force --deep --sign - \
        --identifier com.yabai-dockstack.agent \
        "$APP_PATH"
fi

echo "🚀 Launching..."
open "$APP_PATH"
echo ""
echo "✅ Installation complete!"
