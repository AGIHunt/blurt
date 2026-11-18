#!/bin/zsh
# Builds the sonar test bench into the same private folder as the other capture apps.
set -euo pipefail
dir="${0:A:h}"; app="${1:-$HOME/Library/Application Support/Blurt VSR Pilot/SonarLab.app}"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$dir/bin"
swiftc -O -parse-as-library "$dir/SonarLab.swift" -o "$app/Contents/MacOS/SonarLab"
swiftc -O "$dir/duplex.swift" -o "$dir/bin/duplex"
cp "$dir/tests.json" "$app/Contents/Resources/tests.json"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.blurt.sonar-lab</string>
<key>CFBundleName</key><string>Sonar Lab</string>
<key>CFBundleExecutable</key><string>SonarLab</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSCameraUsageDescription</key><string>Record your mouth locally alongside the sonar so the two can be compared.</string>
<key>NSMotionUsageDescription</key><string>Read AirPods head motion locally so head movement can be separated from mouth movement.</string>
<key>NSMicrophoneUsageDescription</key><string>Record inaudible sonar echoes locally to test mouth sensing.</string>
</dict></plist>
PLIST
codesign --force --sign - "$app"
print -r -- "$app"
