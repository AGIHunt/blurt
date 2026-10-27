#!/bin/sh
# Install Blurt for Mac: download the latest release, put Blurt.app in Applications and open it.
#
#   curl -fsSL https://blurt.agihunt.info/install.sh | sh
#
# Made to be run by you or by your agent (Claude Code, Codex…). It replaces an older Blurt.app where it finds one
# (/Applications, else ~/Applications) and checks that the download is signed and notarized before copying it. The
# permissions (microphone, Accessibility) can only be turned on by you: the setup window that opens walks you through
# them. Served from the website (site/install.sh in github.com/AGIHunt/blurt).
set -eu

URL=https://github.com/AGIHunt/blurt/releases/latest/download/Blurt.dmg

if [ "$(uname -s)" != Darwin ]; then
  echo "Blurt is Mac only for now. Windows and Linux are coming: https://blurt.agihunt.info" >&2
  exit 1
fi
major=$(sw_vers -productVersion | cut -d. -f1)
if [ "$major" -lt 13 ]; then
  echo "Blurt needs macOS 13 or later (this Mac has $(sw_vers -productVersion))." >&2
  exit 1
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/blurt-install.XXXXXX")
MNT=$TMP/mnt
cleanup() {
  hdiutil detach -quiet "$MNT" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

echo "Downloading Blurt (about 20 MB)..."
curl -fsSL -o "$TMP/Blurt.dmg" "$URL"
mkdir "$MNT"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MNT" "$TMP/Blurt.dmg"
NEW=$MNT/Blurt.app
if ! spctl --assess --type execute "$NEW" 2>/dev/null; then
  echo "The download isn't a signed and notarized Blurt.app; nothing was installed." >&2
  exit 1
fi

# where it goes: over an existing copy, else /Applications (~/Applications when that isn't writable);
# BLURT_INSTALL_DIR puts it elsewhere and doesn't quit or open anything (tests)
if [ -n "${BLURT_INSTALL_DIR:-}" ]; then DEST=$BLURT_INSTALL_DIR
elif [ -d /Applications/Blurt.app ]; then DEST=/Applications
elif [ -d "$HOME/Applications/Blurt.app" ]; then DEST=$HOME/Applications
elif [ -w /Applications ]; then DEST=/Applications
else DEST=$HOME/Applications
fi
mkdir -p "$DEST"

if [ -z "${BLURT_INSTALL_DIR:-}" ] && pgrep -xq blurt-recorder; then
  osascript -e 'tell application id "dev.blurt.recorder" to quit' >/dev/null 2>&1 || true
  i=0
  while pgrep -xq blurt-recorder && [ $i -lt 20 ]; do sleep 0.5; i=$((i + 1)); done
fi
rm -rf "$DEST/Blurt.app"
ditto "$NEW" "$DEST/Blurt.app"
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$DEST/Blurt.app/Contents/Info.plist" 2>/dev/null || echo "")
if [ -n "${BLURT_INSTALL_DIR:-}" ]; then
  echo "Blurt $version is in $DEST."
  exit 0
fi
open "$DEST/Blurt.app"

echo "Blurt $version is in $DEST and open."
echo "Finish in the setup window: turn on the microphone and Accessibility, then download the speech models."
echo "To use Blurt from an agent (\"start blurt\"), connect it in Blurt's Settings > Agents."
