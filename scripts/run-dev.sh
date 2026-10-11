#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift build
binary_dir=$(swift build --show-bin-path)
app_dir="$PWD/.build/Development/Web Watcher.app"
# Opening an already-running bundle reuses the old executable. Stop only this checkout's dev app.
for watcher_pid in $(pgrep -x WebWatcher || true); do
    watcher_command=$(ps -p "$watcher_pid" -o command= || true)
    if [[ "$watcher_command" == "$app_dir/Contents/MacOS/WebWatcher" ]]; then
        kill -TERM "$watcher_pid"
        for retry in {1..30}; do
            if ! kill -0 "$watcher_pid" 2>/dev/null; then break; fi
            sleep 0.1
        done
        if kill -0 "$watcher_pid" 2>/dev/null; then
            print -u2 "旧开发版尚未退出，请在菜单栏退出后重试。"
            exit 1
        fi
    fi
done
mkdir -p "$app_dir/Contents/MacOS"
cp "$binary_dir/WebWatcher" "$app_dir/Contents/MacOS/WebWatcher"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
codesign --force --sign - --identifier local.webwatcher.app "$app_dir"
open "$app_dir"
