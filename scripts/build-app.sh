#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="DailyUpdate"
BUILD_DIR="$ROOT/.build/release"
APP_BUNDLE="$ROOT/${APP_NAME}.app"
ICON_SCRIPT="$ROOT/scripts/generate-icon.sh"
ICNS="$ROOT/Assets/AppIcon/AppIcon.icns"

echo "Building $APP_NAME..."
cd "$ROOT"
swift build -c release

echo "Generating app icon..."
chmod +x "$ICON_SCRIPT"
"$ICON_SCRIPT"

echo "Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
if [[ -d "$BUILD_DIR/${APP_NAME}_${APP_NAME}.bundle" ]]; then
    cp -R "$BUILD_DIR/${APP_NAME}_${APP_NAME}.bundle" "$APP_BUNDLE/"
fi
cp "$ROOT/Sources/DailyUpdate/Resources/detectors.json" "$APP_BUNDLE/Contents/Resources/"
mkdir -p "$APP_BUNDLE/Contents/Resources/scripts"
cp "$ROOT/Sources/DailyUpdate/Resources/scripts/check-app-update.sh" "$APP_BUNDLE/Contents/Resources/scripts/"
cp "$ROOT/Sources/DailyUpdate/Resources/scripts/update-app.sh" "$APP_BUNDLE/Contents/Resources/scripts/"
chmod +x "$APP_BUNDLE/Contents/Resources/scripts/check-app-update.sh"
chmod +x "$APP_BUNDLE/Contents/Resources/scripts/update-app.sh"
cp "$ICNS" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

cat > "$APP_BUNDLE/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>DailyUpdate</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.dailyupdate.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Daily Update</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

echo "Done: $APP_BUNDLE"
echo "Run: open \"$APP_BUNDLE\""
