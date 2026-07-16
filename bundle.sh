#!/usr/bin/env bash
#
# Wrap the built binary in a minimal macOS .app bundle.
#
# A bare Mach-O binary launched from a terminal is not treated as a proper
# foreground GUI app: its window shows and receives mouse input, but macOS does
# NOT deliver keyboard events to it (and the Input Method Kit can't attach —
# hence the `IMKCFRunLoopWakeUpReliable` log). Giving it a bundle with an
# Info.plist / bundle identifier fixes keyboard delivery.
#
# Running the inner binary directly (…/Contents/MacOS/Counter) still confers the
# bundle identity AND keeps stdout/stderr on the terminal — handy for debugging.
#
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
EXE="$ROOT/moonbit-bindings/_build/native/debug/build/cmd/main/main.exe"
APP="$ROOT/dist/Counter.app"

if [ ! -f "$EXE" ]; then
  echo "Binary not found — build first: ./build.sh" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$EXE" "$APP/Contents/MacOS/Counter"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Counter</string>
  <key>CFBundleDisplayName</key><string>GPUI + MoonBit Counter</string>
  <key>CFBundleIdentifier</key><string>dev.local.gpui-moonbit.counter</string>
  <key>CFBundleVersion</key><string>0.1.0</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleExecutable</key><string>Counter</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSMinimumSystemVersion</key><string>10.15</string>
</dict>
</plist>
PLIST

echo "Bundled: $APP"
echo "Launch (GUI):        open '$APP'"
echo "Launch (see stderr): '$APP/Contents/MacOS/Counter'"
