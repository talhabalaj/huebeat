#!/bin/sh
# Builds Release (Apple Development signed) and installs it to /Applications.
set -eu
root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$root"
xcodegen generate --quiet
# Xcode doesn't re-seal the app when only helper files change, so always rebuild the bundle itself.
rm -rf build/DerivedData/Build/Products/Release/Huebeat.app
xcodebuild -project Huebeat.xcodeproj -scheme Huebeat -configuration Release \
    -derivedDataPath build/DerivedData -allowProvisioningUpdates -quiet build
app="build/DerivedData/Build/Products/Release/Huebeat.app"
codesign --verify --deep --strict "$app"
osascript -e 'tell application id "me.balaj.Huebeat" to quit' 2>/dev/null || true
while pgrep -xq Huebeat; do sleep 0.2; done
rm -rf /Applications/Huebeat.app
ditto "$app" /Applications/Huebeat.app
echo "Installed /Applications/Huebeat.app"
