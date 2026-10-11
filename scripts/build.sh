#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
bundle="build/Quick Folder Size.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
swiftc -swift-version 5 -O -target arm64-apple-macosx13.0 -framework AppKit Sources/Scanner.swift Sources/App.swift -o "$bundle/Contents/MacOS/QuickFolderSize"
cp Info.plist "$bundle/Contents/Info.plist"
cp LICENSE "$bundle/Contents/Resources/LICENSE"
codesign --force --sign - --identifier local.quickfoldersize.app "$bundle"
codesign --verify --deep --strict "$bundle"
printf 'Built %s\n' "$bundle"
