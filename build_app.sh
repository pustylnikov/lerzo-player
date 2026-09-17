#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd "$DIR"

# Bundle and display name carry a space; the executable and SwiftPM product do not.
APP_NAME="Lerzo Player"
EXECUTABLE="LerzoPlayer"

echo "🔨 Building $APP_NAME (Release)..."
swift build -c release

APP_BUNDLE="$DIR/build/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "📦 Packaging $APP_NAME.app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS"
mkdir -p "$RESOURCES"

# Copy binary
cp "$DIR/.build/release/$EXECUTABLE" "$MACOS/$EXECUTABLE"
chmod +x "$MACOS/$EXECUTABLE"

# UI translations and the app icon (regenerate it with `swift scripts/make_icon.swift`)
cp -R "$DIR"/Resources/*.lproj "$RESOURCES/"
cp "$DIR/Resources/AppIcon.icns" "$RESOURCES/"
cp "$DIR/LICENSE" "$RESOURCES/LICENSE"

# Ensure rpath points to Homebrew lib
install_name_tool -add_rpath "/opt/homebrew/lib" "$MACOS/$EXECUTABLE" 2>/dev/null || true

# Sparkle.framework from the SwiftPM binary artifact, found via @executable_path/../Frameworks.
SPARKLE="$DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
mkdir -p "$CONTENTS/Frameworks"
cp -R "$SPARKLE" "$CONTENTS/Frameworks/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS/$EXECUTABLE" 2>/dev/null || true

# Generate Info.plist
cat << 'EOF' > "$CONTENTS/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>ru</string>
    </array>
    <key>CFBundleExecutable</key>
    <string>LerzoPlayer</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.lerzo.player</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Lerzo Player</string>
    <key>CFBundleDisplayName</key>
    <string>Lerzo Player</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.3.2</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>SUFeedURL</key>
    <string>https://lerzowords.com/player/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>sAd3I+Ud5TSsl2xUaP8J5fhmp5aN9w0JYs7FzjMdd+c=</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 Yurii Pustylnikov. Licensed under the GNU GPL v3.</string>
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

# Sign with a real certificate when one is available. An ad-hoc signature
# changes on every build, so the keychain would treat each build as a new
# app and ask for the login password again whenever the Gemini key is read.
# The hardened runtime and entitlements match scripts/release.sh, so the dev
# build fails the same way a notarized one would (LuaJIT's executable pages
# once killed only the release); the Homebrew dylibs load thanks to
# disable-library-validation.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')}"
if [ -n "$IDENTITY" ]; then
    echo "🔏 Signing with: $IDENTITY"
    SPARKLE_B="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B"
    for item in "$SPARKLE_B/XPCServices/Installer.xpc" "$SPARKLE_B/XPCServices/Downloader.xpc" \
                "$SPARKLE_B/Autoupdate" "$SPARKLE_B/Updater.app" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"; do
        codesign --force --options runtime --sign "$IDENTITY" "$item" 2>&1 | grep -v "replacing existing signature" || true
    done
    codesign --force --options runtime --entitlements "$DIR/scripts/LerzoPlayer.entitlements" \
        --sign "$IDENTITY" "$APP_BUNDLE"
    codesign --verify --deep --strict "$APP_BUNDLE"
else
    echo "⚠️  No Developer ID certificate found — leaving the ad-hoc signature"
fi

echo "✅ Successfully built and packaged: $APP_BUNDLE"
echo "👉 To launch: open \"$APP_BUNDLE\""
