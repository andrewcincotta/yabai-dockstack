#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

APP_PATH="${APP_PATH:-/Applications/yabai-dockstack.app}"
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-debug}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
EXECUTABLE_NAME="yabai-dockstack"

if [[ -z "$SIGN_IDENTITY" ]]; then
    cat >&2 <<'EOF'
error: SIGN_IDENTITY must name a persistent code-signing identity.

Available identities:
    security find-identity -v -p codesigning

Example:
    SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/dev-install.sh

Using ad-hoc signing here would cause macOS to forget Accessibility and Screen
Recording grants after the executable changes.
EOF
    exit 2
fi

case "$BUILD_CONFIGURATION" in
    debug|release) ;;
    *)
        echo "error: BUILD_CONFIGURATION must be 'debug' or 'release'" >&2
        exit 2
        ;;
esac

echo "Building $BUILD_CONFIGURATION configuration..."
swift build -c "$BUILD_CONFIGURATION"

BUILD_DIRECTORY=".build/$BUILD_CONFIGURATION"
BUILT_EXECUTABLE="$BUILD_DIRECTORY/$EXECUTABLE_NAME"

if [[ ! -x "$BUILT_EXECUTABLE" ]]; then
    echo "error: built executable not found at $BUILT_EXECUTABLE" >&2
    exit 1
fi

echo "Stopping the installed app..."
pkill -x "$EXECUTABLE_NAME" 2>/dev/null || true

echo "Updating $APP_PATH..."
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp scripts/Info.plist.template "$APP_PATH/Contents/Info.plist"
[[ ! -f assets/AppIcon.icns ]] || cp assets/AppIcon.icns "$APP_PATH/Contents/Resources/AppIcon.icns"
[[ ! -f assets/menubar.png ]] || cp assets/menubar.png "$APP_PATH/Contents/Resources/menubar.png"

# Replace the executable atomically so the installed bundle remains at one stable path.
EXECUTABLE_TEMP="$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME.new"
cp "$BUILT_EXECUTABLE" "$EXECUTABLE_TEMP"
chmod +x "$EXECUTABLE_TEMP"
mv -f "$EXECUTABLE_TEMP" "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"

for bundle in "$BUILD_DIRECTORY"/*YabaiDockstackKit.bundle; do
    [[ -d "$bundle" ]] || continue
    RESOURCE_DESTINATION="$APP_PATH/Contents/Resources/$(basename "$bundle")"
    rm -rf "$RESOURCE_DESTINATION"
    ditto "$bundle" "$RESOURCE_DESTINATION"
done

echo "Signing with $SIGN_IDENTITY..."
codesign --force --deep --sign "$SIGN_IDENTITY" \
    --identifier com.yabai-dockstack.agent \
    "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"

echo "Launching $APP_PATH..."
open "$APP_PATH"
echo "Development build installed successfully."
