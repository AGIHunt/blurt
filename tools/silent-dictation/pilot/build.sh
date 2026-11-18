#!/bin/zsh
set -euo pipefail
pilot_dir="${0:A:h}"
pilot_app="${1:-$HOME/Library/Application Support/Blurt VSR Pilot/PilotRecorder.app}"
mkdir -p "$pilot_app/Contents/MacOS"
mkdir -p "$pilot_app/Contents/Resources"
cp -R "$pilot_dir/Resources/" "$pilot_app/Contents/Resources/"
swiftc -O -parse-as-library "$pilot_dir/PilotRecorder.swift" "$pilot_dir/Localization.swift" -o "$pilot_app/Contents/MacOS/PilotRecorder"
cat > "$pilot_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.blurt.vsr-pilot</string>
<key>CFBundleName</key><string>Silent Dictation Pilot</string>
<key>CFBundleExecutable</key><string>PilotRecorder</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string><string>zh-Hant</string></array>
<key>NSCameraUsageDescription</key><string>Record locally reviewed mouth movements for your silent dictation experiment.</string>
<key>NSMicrophoneUsageDescription</key><string>Optionally record audio for voiced or whispered comparison takes, only when you select audio.</string>
</dict></plist>
PLIST
codesign --force --sign - "$pilot_app"
print -r -- "$pilot_app"
