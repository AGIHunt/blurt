#!/usr/bin/env bash
# Release Blurt.app for macOS: universal build with Sparkle → Developer ID signing (hardened runtime) → DMG →
# notarization + stapling → Sparkle update zip + EdDSA-signed appcast.xml.
#
#   scripts/release-mac.sh [--dry-run] [--version X.Y.Z] [--out DIR] [--archives DIR]
#
# --archives DIR keeps the update zips + appcast.xml of earlier releases (generate_appcast's archives directory):
# with them there, Sparkle delta updates from those versions are generated too (*.delta, attach them as well).
#
# Without a "Developer ID Application" certificate in the keychain it runs as a DRY RUN on its own: the app stays
# ad-hoc signed, notarization is skipped (the commands are printed), and the appcast is signed with a throwaway key —
# every step still runs, so the pipeline is tested end to end. Nothing is uploaded; attach $OUT/* to the GitHub release
# (the feed URL in Info.plist is …/releases/latest/download/appcast.xml).
#
# Environment (real releases; all optional in a dry run):
#   DEVELOPER_ID           "Developer ID Application: Name (TEAMID)"   (default: the first one in the keychain)
#   NOTARY_PROFILE         `xcrun notarytool store-credentials` profile name (default: blurt-notary)
#   SPARKLE_PUBLIC_ED_KEY  base64 public key → Info.plist SUPublicEDKey     (default: `generate_keys -p` from the keychain)
#   SPARKLE_ED_KEY_FILE    private key file for generate_appcast           (default: the keychain, account ed25519)
#   RELEASE_TAG            download prefix tag (default: v$VERSION)
# Needs: macOS, the Command Line Tools (swift), uv. Not shipped with the skill (lives outside skills/).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
MAC=$ROOT/skills/blurt/recorder/macos
SPARKLE_VERSION=$(sed -n 's/^let sparkleVersion = "\([^"]*\)".*/\1/p' "$MAC/Package.swift")
SPARKLE_SHA=$(sed -n 's/^let sparkleChecksum = "\([^"]*\)".*/\1/p' "$MAC/Package.swift")
REPO_URL=https://github.com/AGIHunt/blurt

DRY=0
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$MAC/Info.plist")
OUT=$ROOT/dist/macos
ARCHIVES=
while [ $# -gt 0 ]; do
  case $1 in
    --dry-run) DRY=1 ;;
    --version) VERSION=$2; shift ;;
    --out) OUT=$2; shift ;;
    --archives) ARCHIVES=$2; shift ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
BUILD=$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || date +%Y%m%d%H%M)   # CFBundleVersion: grows with every commit
TAG=${RELEASE_TAG:-v$VERSION}

say() { printf '\033[1m==> %s\033[0m\n' "$*" >&2; }
would() { printf '    (dry run) would run: %s\n' "$*" >&2; }

if [ -z "${DEVELOPER_ID:-}" ]; then
  DEVELOPER_ID=$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
fi
if [ -z "$DEVELOPER_ID" ] && [ $DRY = 0 ]; then
  say "no Developer ID Application certificate in the keychain → DRY RUN"
  DRY=1
fi
[ $DRY = 1 ] && DEVELOPER_ID=""

WORK=$(mktemp -d "${TMPDIR:-/tmp}/blurt-release.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
rm -rf "$OUT" && mkdir -p "$OUT"

# ---------------------------------------------------------------- Sparkle tools (same pinned artifact as Package.swift)
say "Sparkle $SPARKLE_VERSION tools"
CACHE=${XDG_CACHE_HOME:-$HOME/Library/Caches}/blurt-release
mkdir -p "$CACHE"
ZIP=$CACHE/Sparkle-$SPARKLE_VERSION-spm.zip
if [ ! -f "$ZIP" ] || [ "$(shasum -a 256 "$ZIP" | cut -d' ' -f1)" != "$SPARKLE_SHA" ]; then
  curl -fsSL -o "$ZIP" "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-for-Swift-Package-Manager.zip"
fi
[ "$(shasum -a 256 "$ZIP" | cut -d' ' -f1)" = "$SPARKLE_SHA" ] || { echo "Sparkle zip checksum mismatch" >&2; exit 1; }
unzip -q -o "$ZIP" 'bin/*' -d "$WORK/sparkle"
SPK=$WORK/sparkle/bin

# ---------------------------------------------------------------- EdDSA keys
KEYFILE=${SPARKLE_ED_KEY_FILE:-}
PUBKEY=${SPARKLE_PUBLIC_ED_KEY:-}
if [ $DRY = 1 ] && [ -z "$KEYFILE" ]; then
  say "throwaway EdDSA key (dry run)"
  KEYS=$(uv run -q --with cryptography python3 -c '
import base64
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization as s
k = Ed25519PrivateKey.generate()
raw = lambda b: base64.b64encode(b).decode()
print(raw(k.private_bytes(s.Encoding.Raw, s.PrivateFormat.Raw, s.NoEncryption())),
      raw(k.public_key().public_bytes(s.Encoding.Raw, s.PublicFormat.Raw)))')
  KEYFILE=$WORK/ed25519.key
  printf '%s' "${KEYS% *}" > "$KEYFILE"
  PUBKEY=${KEYS#* }
fi
if [ -z "$PUBKEY" ]; then
  PUBKEY=$("$SPK/generate_keys" -p 2>/dev/null || true)
fi
[ -n "$PUBKEY" ] || { echo "no Sparkle public key: set SPARKLE_PUBLIC_ED_KEY or run $SPK/generate_keys once" >&2; exit 1; }

# ---------------------------------------------------------------- build
say "build $VERSION ($BUILD): universal + Sparkle"
mkdir -p "$WORK/home"
echo '{"record": {"install_app": false}}' > "$WORK/home/config.json"
BLURT_HOME=$WORK/home BLURT_WORKSPACE=$WORK/ws BLURT_UNIVERSAL=1 BLURT_SPARKLE=1 \
  uv run -q "$ROOT/skills/blurt/scripts/record.py" build >/dev/null
APP=$OUT/Blurt.app
ditto "$WORK/home/Blurt.app" "$APP"
rm -f "$APP/Contents/Resources/source.sha"
PB=/usr/libexec/PlistBuddy
$PB -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" -c "Set :SUPublicEDKey $PUBKEY" \
  "$APP/Contents/Info.plist"

# ---------------------------------------------------------------- sign
ENT=$WORK/entitlements.plist
cat > "$ENT" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.device.audio-input</key><true/>
</dict></plist>
PLIST
FW=$APP/Contents/Frameworks/Sparkle.framework
if [ -n "$DEVELOPER_ID" ]; then
  say "sign: $DEVELOPER_ID (hardened runtime)"
  CS=(codesign --force --timestamp --options runtime --sign "$DEVELOPER_ID")
  "${CS[@]}" "$FW/Versions/B/Autoupdate"
  "${CS[@]}" "$FW/Versions/B/Updater.app"
  "${CS[@]}" "$FW"
  "${CS[@]}" --entitlements "$ENT" "$APP"
else
  say "sign: ad hoc (dry run)"
  for x in "$FW/Versions/B/Autoupdate" "$FW/Versions/B/Updater.app" "$FW"; do codesign --force --sign - "$x"; done
  codesign --force --sign - --entitlements "$ENT" --identifier dev.blurt.recorder \
    -r='designated => identifier "dev.blurt.recorder"' "$APP"
  would codesign --force --timestamp --options runtime --sign '"Developer ID Application: …"' "(Sparkle parts, then the app with $ENT)"
fi
codesign --verify --deep --strict "$APP"

# ---------------------------------------------------------------- DMG
say "DMG"
STAGE=$WORK/dmg
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Blurt.app"
ln -s /Applications "$STAGE/Applications"
DMG=$OUT/Blurt-$VERSION.dmg
hdiutil create -quiet -volname "Blurt $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 "$DMG"
[ -n "$DEVELOPER_ID" ] && codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"

# ---------------------------------------------------------------- notarize + staple
PROFILE=${NOTARY_PROFILE:-blurt-notary}
if [ -n "$DEVELOPER_ID" ]; then
  say "notarize (profile $PROFILE)"
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler staple "$APP"       # the DMG's ticket covers the app inside it
  spctl --assess --type execute --verbose "$APP"
else
  would xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  would xcrun stapler staple "$DMG" '&&' xcrun stapler staple "$APP"
fi

# ---------------------------------------------------------------- Sparkle update + appcast
say "appcast"
UPD=${ARCHIVES:-$WORK/updates}
mkdir -p "$UPD"
UZIP=Blurt-$VERSION.zip
ditto -c -k --sequesterRsrc --keepParent "$APP" "$UPD/$UZIP"
GA=("$SPK/generate_appcast" --download-url-prefix "$REPO_URL/releases/download/$TAG/" --link "$REPO_URL")
[ -n "$KEYFILE" ] && GA+=(--ed-key-file "$KEYFILE")
"${GA[@]}" "$UPD"
cp "$UPD/$UZIP" "$UPD/appcast.xml" "$OUT/"
cp "$UPD"/*.delta "$OUT/" 2>/dev/null || true
SIG=$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' "$OUT/appcast.xml" | head -1)
VERIFY=(--verify "$OUT/$UZIP" "$SIG")
if [ -n "$KEYFILE" ]; then "$SPK/sign_update" --ed-key-file "$KEYFILE" "${VERIFY[@]}"; else "$SPK/sign_update" "${VERIFY[@]}"; fi

size() { du -sk "$1" | cut -f1; }
APPBYTES=$(find "$APP" -type f -exec stat -f %z {} + | awk '{s+=$1} END {print s}')
cat <<JSON
{"dry_run": $([ $DRY = 1 ] && echo true || echo false), "version": "$VERSION", "build": "$BUILD",
 "app": "$APP", "app_bytes": $APPBYTES, "dmg": "$DMG", "dmg_kb": $(size "$DMG"),
 "update_zip": "$OUT/$UZIP", "zip_kb": $(size "$OUT/$UZIP"), "appcast": "$OUT/appcast.xml",
 "sparkle": "$SPARKLE_VERSION", "public_key": "$PUBKEY"}
JSON
