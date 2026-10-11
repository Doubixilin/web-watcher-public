#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift build -c release
binary_dir=$(swift build -c release --show-bin-path)
app_dir="$PWD/build/Web Watcher.app"
mkdir -p "$app_dir/Contents/MacOS"
cp "$binary_dir/WebWatcher" "$app_dir/Contents/MacOS/WebWatcher"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
codesign --force --sign - "$app_dir"
print -r -- "$app_dir"
