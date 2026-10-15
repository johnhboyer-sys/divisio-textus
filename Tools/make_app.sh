#!/bin/bash
# Builds "Divisio Textus.app" — a self-contained, ad-hoc-signed macOS bundle from the
# SwiftPM executable. Re-runnable; output goes to dist/.
set -euo pipefail

APP_NAME="Divisio Textus"
BUNDLE_ID="com.johnboyer.divisiotextus"
VERSION="1.0"
BUILD="1"

PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJ_DIR"

# Universal (arm64 + x86_64) build. Swift 6.4's build system does this directly;
# the older approach (one -Xswiftc -target build per arch, then lipo) now links
# the wrong architecture.
echo "==> Building universal binary"
BUILD_ARGS=(-c release --arch arm64 --arch x86_64 --build-path .build-universal)
swift build "${BUILD_ARGS[@]}"
BIN="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)/PDFCropper"
[ -x "$BIN" ] || { echo "universal binary not produced"; exit 1; }
echo "    architectures: $(lipo -archs "$BIN")"

APP="$PROJ_DIR/dist/$APP_NAME.app"
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
chmod +x "$APP/Contents/MacOS/$APP_NAME"

echo "==> Generating icon"
ICON_TMP="$(mktemp -d)"
ICONSET="$ICON_TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
swiftc "$PROJ_DIR/Tools/gen_icon.swift" -o "$ICON_TMP/gen_icon"
"$ICON_TMP/gen_icon" "$ICON_TMP/icon_1024.png"
make_size() { sips -z "$1" "$1" "$ICON_TMP/icon_1024.png" --out "$ICONSET/$2" >/dev/null; }
make_size 16   icon_16x16.png
make_size 32   icon_16x16@2x.png
make_size 32   icon_32x32.png
make_size 64   icon_32x32@2x.png
make_size 128  icon_128x128.png
make_size 256  icon_128x128@2x.png
make_size 256  icon_256x256.png
make_size 512  icon_256x256@2x.png
make_size 512  icon_512x512.png
make_size 1024 icon_512x512@2x.png
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> Writing Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>PDF document</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSItemContentTypes</key>
            <array><string>com.adobe.pdf</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Ad-hoc code signing"
xattr -cr "$APP"   # strip extended attributes codesign rejects as "detritus"
codesign --force --deep --sign - "$APP"
codesign --verify --verbose "$APP" || true

echo "==> Done: $APP"
