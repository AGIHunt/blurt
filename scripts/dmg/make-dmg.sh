#!/usr/bin/env bash
# Build the Blurt macOS installer window.
#
#   scripts/dmg/make-dmg.sh --app path/to/Blurt.app [--version X.Y.Z] [--out DIR]
#
# The window is a fixed 720×460 canvas: the app on the left, an Applications link on the right, a white card and
# "Drag to" in between. The artwork lives in scripts/dmg/background.svg (source) and background.png /
# background@2x.png (exports). Finder lays both icons out on a read-write image, then the image is converted to
# UDZO; signing and notarization stay in scripts/release-mac.sh.
#
# Needs macOS built-ins only: hdiutil, tiffutil, osascript (a logged-in Finder session for the icon layout; if
# Finder is unavailable the DMG is still built, with Finder's default layout).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
APP=
VERSION=
OUT=$ROOT/dist/macos
VOLNAME=

while [ $# -gt 0 ]; do
  case $1 in
    --app) APP=$2; shift ;;
    --version) VERSION=$2; shift ;;
    --out) OUT=$2; shift ;;
    --volname) VOLNAME=$2; shift ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

[ -n "$APP" ] && [ -d "$APP" ] || { echo "--app must point to a .app bundle" >&2; exit 2; }
[ -n "$VERSION" ] || VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
APP_NAME=$(/usr/libexec/PlistBuddy -c "Print :CFBundleName" "$APP/Contents/Info.plist")
[ -n "$APP_NAME" ] || APP_NAME=Blurt
[ -n "$VOLNAME" ] || VOLNAME="$APP_NAME $VERSION"
NAME="$APP_NAME.app"

BG=$ROOT/scripts/dmg
for f in background.png background@2x.png; do
  [ -f "$BG/$f" ] || { echo "missing $BG/$f; export the artwork from scripts/dmg/background.svg" >&2; exit 1; }
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/blurt-dmg.XXXXXX")
MOUNT=
cleanup() {
  [ -n "$MOUNT" ] && { hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || hdiutil detach "$MOUNT" -force -quiet >/dev/null 2>&1 || true; }
  rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$OUT" "$WORK/stage/.background"
ditto "$APP" "$WORK/stage/$NAME"
ln -s /Applications "$WORK/stage/Applications"
cp "$BG/background.png" "$BG/background@2x.png" "$WORK/stage/.background/"
# One multi-resolution TIFF: Finder picks the 144 dpi page on Retina displays.
tiffutil -cathidpicheck "$WORK/stage/.background/background.png" "$WORK/stage/.background/background@2x.png" \
  -out "$WORK/stage/.background/background.tiff" >/dev/null
rm -f "$WORK/stage/.background/background.png" "$WORK/stage/.background/background@2x.png"

RW=$WORK/rw.dmg
hdiutil create -quiet -srcfolder "$WORK/stage" -volname "$VOLNAME" -fs HFS+ -format UDRW -ov "$RW"
MOUNT=$(hdiutil attach -nobrowse -noautoopen "$RW" | awk -F'\t' 'END { print $NF }')
[ -n "$MOUNT" ] && [ -d "$MOUNT" ] || { echo "could not mount $RW" >&2; exit 1; }
# Finder names the volume after its mount point; use that so a second mount of the same version still works.
VOLNAME=$(basename "$MOUNT")

# Finder writes .DS_Store: background, window bounds, icon size and the two icon positions. The background is
# 720×460 pt, so the window is 720×488 with the title bar. Positions are icon centres in content coordinates.
LAYOUT_LOG=$WORK/finder.log
if osascript - "$VOLNAME" "$NAME" "$MOUNT" >"$LAYOUT_LOG" 2>&1 <<'APPLESCRIPT'
on run argv
  set volName to item 1 of argv
  set appName to item 2 of argv
  tell application "Finder"
    activate
    set d to disk volName
    tell d
      open
      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      try
        set sidebar width of container window to 0
      end try
      set the bounds of container window to {200, 120, 920, 608}
      set vo to the icon view options of container window
      set arrangement of vo to not arranged
      set icon size of vo to 104
      set text size of vo to 12
      set label position of vo to bottom
      set shows item info of vo to false
      set shows icon preview of vo to true
      set background picture of vo to file ".background:background.tiff"
      set position of item appName of container window to {208, 320}
      set position of item "Applications" of container window to {512, 320}
      close
      open
      update without registering applications
      delay 1
      close
    end tell
  end tell
end run
APPLESCRIPT
then
  :
else
  echo "warning: Finder layout failed (no GUI session?); the DMG will use Finder's default layout" >&2
  sed 's/^/    /' "$LAYOUT_LOG" >&2 || true
fi

sync
sleep 1
hdiutil detach "$MOUNT" -quiet || hdiutil detach "$MOUNT" -force -quiet

DMG=$OUT/$APP_NAME-$VERSION.dmg
rm -f "$DMG"
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG"
echo "DMG: $DMG"
