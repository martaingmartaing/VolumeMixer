#!/bin/bash
# Builds build/VolumeMixer.app (universal binary) and the build/VolumeMixer.dmg installer.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="1.0.0"
APP="build/VolumeMixer.app"
DMG="build/VolumeMixer.dmg"
ARCHS=(--arch arm64 --arch x86_64)

swift build -c release "${ARCHS[@]}"

rm -rf build
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release "${ARCHS[@]}" --show-bin-path)/VolumeMixer" "$APP/Contents/MacOS/VolumeMixer"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>VolumeMixer</string>
    <key>CFBundleDisplayName</key><string>Volume Mixer</string>
    <key>CFBundleIdentifier</key><string>local.volumemixer</string>
    <key>CFBundleExecutable</key><string>VolumeMixer</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.2</string>
    <key>LSUIElement</key><true/>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Volume Mixer needs access to app audio in order to adjust each app's volume individually.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature (no Apple developer certificate).
codesign --force --sign - "$APP"

# Installer disk image: drag the app onto the Applications shortcut.
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Volume Mixer" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null

echo "OK: $APP"
echo "OK: $DMG"
