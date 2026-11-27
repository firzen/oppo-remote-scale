#!/bin/sh
set -eu
cd "$(dirname "$0")"
app="build/OPPO 远控分辨率助手.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" build/objects
for arch in x86_64 arm64; do
    target="$arch-apple-macosx15.0"
    xcrun swiftc -swift-version 6 -target "$target" -parse-as-library \
        Sources/Todo/DingTalkClient.swift Sources/Todo/TodoController.swift \
        -emit-object -whole-module-optimization -module-name TodoBridge \
        -emit-objc-header-path build/objects/TodoBridge.h -o "build/objects/Todo-$arch.o"
    xcrun clang -arch "$arch" -fobjc-arc -Wall -Wextra -Wno-unused-parameter \
        -mmacosx-version-min=15.0 -I build/objects -c main.m -o "build/objects/Main-$arch.o"
    xcrun swiftc -target "$target" "build/objects/Main-$arch.o" "build/objects/Todo-$arch.o" \
        -framework AppKit -framework CoreGraphics -framework ColorSync -o "build/objects/RemoteScale-$arch"
    xcrun swiftc -swift-version 6 -target "$target" -parse-as-library \
        Sources/Todo/DingTalkClient.swift Sources/Todo/NotesSynchronizer.swift Sources/Todo/NotesHelper.swift \
        -o "build/objects/TodoNotesHelper-$arch"
done
xcrun lipo -create build/objects/RemoteScale-x86_64 build/objects/RemoteScale-arm64 -output "$app/Contents/MacOS/RemoteScale"
xcrun lipo -create build/objects/TodoNotesHelper-x86_64 build/objects/TodoNotesHelper-arm64 -output "$app/Contents/MacOS/TodoNotesHelper"
cp assets/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app/Contents/MacOS/TodoNotesHelper"
codesign --force --sign - "$app"
printf '%s\n' "$PWD/$app"
