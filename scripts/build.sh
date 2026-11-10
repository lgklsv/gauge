#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP="$PWD/build/Gauge.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Gauge "$APP/Contents/MacOS/Gauge"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/CodexMark.png Resources/ClaudeMark.png "$APP/Contents/Resources/"
swift scripts/make-icon.swift "$PWD/build"
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
# Local ad-hoc signing needs no developer account, certificate, or notarization.
codesign --force --sign - "$APP"
printf '\nBuilt %s\n' "$APP"
