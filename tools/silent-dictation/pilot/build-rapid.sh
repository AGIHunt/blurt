#!/bin/zsh
set -euo pipefail
dir="${0:A:h}"; app="${1:-$HOME/Library/Application Support/Blurt VSR Pilot/RapidRecorder.app}"
mkdir -p "$app/Contents/MacOS"
swiftc -O -parse-as-library "$dir/RapidRecorder.swift" -o "$app/Contents/MacOS/RapidRecorder"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.blurt.vsr-rapid</string>
<key>CFBundleName</key><string>Rapid Recorder</string>
<key>CFBundleExecutable</key><string>RapidRecorder</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSCameraUsageDescription</key><string>Record your mouth locally for your own lip-reading model.</string>
<key>NSMicrophoneUsageDescription</key><string>Record voiced sentences locally so they can be checked against the script.</string>
</dict></plist>
PLIST
codesign --force --sign - "$app"
print -r -- "$app"
