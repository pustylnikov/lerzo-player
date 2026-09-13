#!/bin/bash
# Builds a self-contained, signed (and optionally notarized) "Lerzo Player.app" and a
# DMG. Unlike build_app.sh (which links against Homebrew for fast dev cycles)
# this copies libmpv and its whole dependency tree into the bundle.
#
#   scripts/release.sh                       # ad-hoc signed, for local testing
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" scripts/release.sh
#   SIGN_IDENTITY=... NOTARY_PROFILE=<profile> scripts/release.sh   # + notarize
#
# NOTARY_PROFILE is a keychain profile created once with
#   xcrun notarytool store-credentials <profile> --apple-id ... --team-id ... --password <app-specific>
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

APP_NAME="Lerzo Player"
EXECUTABLE="LerzoPlayer"
VERSION="${VERSION:-$(grep -A1 CFBundleShortVersionString build_app.sh | grep -o '[0-9][0-9.]*')}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
BREW_PREFIX="$(brew --prefix)"

OUT="$DIR/dist"
APP="$OUT/$APP_NAME.app"
CONTENTS="$APP/Contents"
FRAMEWORKS="$CONTENTS/Frameworks"
RESOURCES="$CONTENTS/Resources"
DMG="$OUT/$EXECUTABLE-$VERSION.dmg"

echo "🔨 Building $APP_NAME $VERSION ($BUILD_NUMBER), release…"
swift build -c release 2>&1 | tail -1

echo "📦 Assembling bundle…"
rm -rf "$OUT"; mkdir -p "$CONTENTS/MacOS" "$FRAMEWORKS" "$RESOURCES"
cp ".build/release/$EXECUTABLE" "$CONTENTS/MacOS/$EXECUTABLE"

# Reuse the Info.plist template from the dev script, then stamp the version.
./build_app.sh >/dev/null
cp "build/$APP_NAME.app/Contents/Info.plist" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$CONTENTS/Info.plist"
cp -R "$DIR"/Resources/*.lproj "$RESOURCES/"
cp "$DIR/Resources/AppIcon.icns" "$RESOURCES/"

# --- Bundle libmpv + every Homebrew dylib it pulls in --------------------------
# Each library is copied under its real file name, its install name becomes
# @rpath/<name>, and every reference to a Homebrew path is rewritten to match.
echo "📚 Bundling dylibs…"
python3 - "$CONTENTS/MacOS/$EXECUTABLE" "$FRAMEWORKS" "$BREW_PREFIX" <<'PY'
import os, shutil, subprocess, sys
exe, frameworks, brew = sys.argv[1:]

def links(path):
    out = subprocess.run(["otool", "-L", path], capture_output=True, text=True, check=True).stdout
    return [l.split()[0] for l in out.splitlines()[1:] if l.strip().startswith(brew)]

# MoltenVK is loaded by the Vulkan loader through an ICD manifest, so it never
# shows up in otool output; seed it explicitly.
roots = [f"{brew}/opt/mpv/lib/libmpv.2.dylib", f"{brew}/opt/molten-vk/lib/libMoltenVK.dylib"]
queue, real_of = roots + links(exe), {}
while queue:
    ref = queue.pop(0)
    real = os.path.realpath(ref)
    if ref in real_of: continue
    real_of[ref] = real
    queue.extend(links(real))

copied = {}
for ref, real in real_of.items():
    name = os.path.basename(real)
    dest = os.path.join(frameworks, name)
    if real not in copied:
        shutil.copy2(real, dest); os.chmod(dest, 0o755)
        copied[real] = dest
    real_of[ref] = dest

def fix(binary, is_lib):
    cmd = ["install_name_tool"]
    if is_lib: cmd += ["-id", "@rpath/" + os.path.basename(binary)]
    for ref in links(binary):
        cmd += ["-change", ref, "@rpath/" + os.path.basename(real_of[ref])]
    cmd += ["-add_rpath", "@loader_path" if is_lib else "@executable_path/../Frameworks", binary]
    subprocess.run(cmd, check=True, capture_output=True)

for dest in copied.values(): fix(dest, True)
fix(exe, False)
print(f"   {len(copied)} libraries")
PY
# The dev build added a Homebrew rpath; a release bundle must not have one.
install_name_tool -delete_rpath "$BREW_PREFIX/lib" "$CONTENTS/MacOS/$EXECUTABLE" 2>/dev/null || true

# Vulkan ICD manifest pointing at the bundled MoltenVK (path is relative to the JSON).
mkdir -p "$RESOURCES/vulkan/icd.d"
cat > "$RESOURCES/vulkan/icd.d/MoltenVK_icd.json" <<'JSON'
{
    "file_format_version": "1.0.0",
    "ICD": {
        "library_path": "../../../Frameworks/libMoltenVK.dylib",
        "api_version": "1.4.0",
        "is_portability_driver": true
    }
}
JSON

# Sanity check: nothing may still point at Homebrew.
if otool -L "$CONTENTS/MacOS/$EXECUTABLE" "$FRAMEWORKS"/*.dylib | grep -q "$BREW_PREFIX"; then
    echo "❌ Homebrew references remain:"; otool -L "$CONTENTS/MacOS/$EXECUTABLE" "$FRAMEWORKS"/*.dylib | grep "$BREW_PREFIX"; exit 1
fi

# --- Sign -----------------------------------------------------------------------
echo "✍️  Signing with: $SIGN_IDENTITY"
ENTITLEMENTS="$DIR/scripts/LerzoPlayer.entitlements"
for lib in "$FRAMEWORKS"/*.dylib; do
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$lib" 2>&1 | grep -v "replacing existing signature" || true
done
codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

# --- DMG ------------------------------------------------------------------------
echo "💿 Creating DMG…"
STAGE="$OUT/dmg"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"

# --- Notarize -------------------------------------------------------------------
if [ -n "$NOTARY_PROFILE" ]; then
    echo "🍎 Notarizing (this takes a few minutes)…"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    xcrun stapler staple "$APP"
    spctl --assess --type open --context context:primary-signature -v "$DMG"
else
    echo "ℹ️  Skipped notarization (set NOTARY_PROFILE). Gatekeeper will block this build on other Macs."
fi

echo "✅ $DMG ($(du -h "$DMG" | cut -f1))"
