#!/usr/bin/env bash
# Quick install script for local development - replaces your current installation
# with the newly built version. Uses ad-hoc signing (fine for local use).
set -euo pipefail

cd "$(dirname "$0")"

APP_PATH="/Applications/yabai-dockstack.app"
EXECUTABLE_NAME="yabai-dockstack"

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

# Copy the executable
echo "📝 Copying executable..."
EXECUTABLE_TEMP="$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME.new"
cp "$BUILT_EXECUTABLE" "$EXECUTABLE_TEMP"
chmod +x "$EXECUTABLE_TEMP"
mv -f "$EXECUTABLE_TEMP" "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"

# Copy resource bundles
echo "📚 Copying resource bundles..."
for bundle in "$BUILD_DIRECTORY"/*YabaiDockstackKit.bundle; do
    [[ -d "$bundle" ]] || continue
    RESOURCE_DESTINATION="$APP_PATH/Contents/Resources/$(basename "$bundle")"
    rm -rf "$RESOURCE_DESTINATION"
    ditto "$bundle" "$RESOURCE_DESTINATION"
done

echo "✍️  Ad-hoc signing (sufficient for local use)..."
codesign --force --deep --sign - \
    --identifier com.yabai-dockstack.agent \
    "$APP_PATH"

echo "🚀 Launching updated app..."
open "$APP_PATH"

echo ""
echo "✅ Installation complete!"
echo ""
echo "Note: If you see permission prompts, grant Accessibility and Screen Recording"
echo "      permissions again (macOS sometimes forgets on unsigned builds)."
