#!/bin/zsh
# Builds PhotoSweep and assembles build/PhotoSweep.app.
# Needs only the Command Line Tools (no Xcode): the bundle is put together by hand and ad-hoc signed.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="build/PhotoSweep.app"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/PhotoSweep "$APP/Contents/MacOS/PhotoSweep"
cp Support/Info.plist "$APP/Contents/Info.plist"
if [[ -f Support/AppIcon.icns ]]; then
    cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

codesign --force --sign - --identifier app.photosweep.PhotoSweep "$APP"
codesign --verify --strict "$APP"

echo "Built $PWD/$APP"
echo "Open it with: open \"$PWD/$APP\""
