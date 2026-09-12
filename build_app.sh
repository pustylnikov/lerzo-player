#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd "$DIR"

echo "🔨 Building VPlayer (Release)..."
swift build -c release

APP_NAME="VPlayer"
APP_BUNDLE="$DIR/build/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "📦 Packaging $APP_NAME.app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS"
mkdir -p "$RESOURCES"

# Copy binary
cp "$DIR/.build/release/VPlayer" "$MACOS/$APP_NAME"
chmod +x "$MACOS/$APP_NAME"

# Ensure rpath points to Homebrew lib
install_name_tool -add_rpath "/opt/homebrew/lib" "$MACOS/$APP_NAME" 2>/dev/null || true

# Generate Info.plist
cat << 'EOF' > "$CONTENTS/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>VPlayer</string>
    <key>CFBundleIdentifier</key>
    <string>com.vplayer.mac</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>VPlayer</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026. All rights reserved.</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Video File</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>mkv</string>
                <string>mp4</string>
                <string>mov</string>
                <string>avi</string>
                <string>webm</string>
                <string>m4v</string>
                <string>srt</string>
                <string>ass</string>
                <string>vtt</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
EOF

echo "✅ Successfully built and packaged: $APP_BUNDLE"
echo "👉 To launch: open \"$APP_BUNDLE\""
