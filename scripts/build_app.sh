#!/usr/bin/env bash
# Builds "Photo Rotator.app" from the Swift package. Needs Xcode or the Command Line Tools (Swift 5.9+).
#
#   scripts/build_app.sh            # release build into build/Photo Rotator.app
#   CONFIG=debug scripts/build_app.sh
#
# The app is signed ad hoc so it can run on this Mac. macOS asks for Photos access on first launch;
# after a rebuild it may ask again, because the ad-hoc signature changes.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
APP="build/Photo Rotator.app"

swift build -c "$CONFIG" --product PhotoRotator
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/PhotoRotator" "$APP/Contents/MacOS/PhotoRotator"
cp Support/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# The orientation network. Compiled now if Xcode's Core ML compiler is available; otherwise the package is bundled
# as is and the app compiles it once on first use.
if [ -d Models/OrientationNet.mlpackage ]; then
    if xcrun --find coremlcompiler >/dev/null 2>&1; then
        xcrun coremlcompiler compile Models/OrientationNet.mlpackage "$APP/Contents/Resources" >/dev/null
    else
        cp -R Models/OrientationNet.mlpackage "$APP/Contents/Resources/"
    fi
fi

codesign --force --sign - --entitlements Support/PhotoRotator.entitlements "$APP"

echo "Built $APP"
echo "Run it with: open \"$APP\""
