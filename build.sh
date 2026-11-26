#!/bin/sh
set -eu

cd "$(dirname "$0")"
app="build/OPPO 远控分辨率助手.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

xcrun clang -arch x86_64 -arch arm64 -fobjc-arc -Wall -Wextra -Wno-unused-parameter \
    -mmacosx-version-min=15.0 -framework AppKit -framework CoreGraphics -framework ColorSync \
    main.m -o "$app/Contents/MacOS/RemoteScale"

cp assets/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
printf '%s\n' "$PWD/$app"
