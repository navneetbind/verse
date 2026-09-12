#!/bin/bash
# Verse for YT Music — one-command installer (macOS).
# Builds the menu-bar app, gives the extension a stable Chrome ID, and installs
# the native-messaging host manifest for every browser you have.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT="$ROOT/extension"
MENUBAR="$ROOT/menubar"
KEY_PEM="$ROOT/.chrome-key.pem" # private key -> deterministic Chrome extension id
FF_ID="verse@local"
HOST_NAME="verse"

echo "==> Building menu-bar app (release)…"
( cd "$MENUBAR" && swift build -c release )
BIN="$(cd "$MENUBAR" && python3 -c "import os;print(os.path.realpath('.build/release/verse'))")"
echo "    binary: $BIN"

echo "==> Preparing Chrome extension key…"
if [ ! -f "$KEY_PEM" ]; then
  openssl genrsa 2048 >"$KEY_PEM" 2>/dev/null
  echo "    generated $KEY_PEM"
fi
PUB_B64="$(openssl rsa -in "$KEY_PEM" -pubout -outform DER 2>/dev/null | base64 | tr -d '\n')"
# Chrome id = first 128 bits of sha256(DER SPKI), hex mapped 0-9a-f -> a-p
CHROME_ID="$(openssl rsa -in "$KEY_PEM" -pubout -outform DER 2>/dev/null \
  | openssl dgst -sha256 -binary | head -c16 | xxd -p | tr '0-9a-f' 'a-p')"
echo "    chrome extension id: $CHROME_ID"

echo "==> Injecting key into extension/manifest.json…"
python3 - "$EXT/manifest.json" "$PUB_B64" <<'PY'
import json, sys
path, key = sys.argv[1], sys.argv[2]
m = json.load(open(path))
m["key"] = key
json.dump(m, open(path, "w"), indent=2)
open(path, "a").write("\n")
PY

# native host manifest bodies
ff_manifest() {
  cat <<EOF
{
  "name": "$HOST_NAME",
  "description": "Verse menu-bar lyrics host",
  "path": "$BIN",
  "type": "stdio",
  "allowed_extensions": ["$FF_ID"]
}
EOF
}
chrome_manifest() {
  cat <<EOF
{
  "name": "$HOST_NAME",
  "description": "Verse menu-bar lyrics host",
  "path": "$BIN",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://$CHROME_ID/"]
}
EOF
}

APPSUP="$HOME/Library/Application Support"
install_host() { # $1 = parent app-support dir, $2 = gecko|chromium
  local base="$1"
  [ -d "$base" ] || return 0
  local dir="$base/NativeMessagingHosts"
  mkdir -p "$dir"
  if [ "$2" = "gecko" ]; then ff_manifest >"$dir/$HOST_NAME.json"; else chrome_manifest >"$dir/$HOST_NAME.json"; fi
  echo "    installed: $dir/$HOST_NAME.json"
}

echo "==> Installing native-messaging host manifests…"
install_host "$APPSUP/Mozilla" gecko
install_host "$APPSUP/Google/Chrome" chromium
install_host "$APPSUP/Google/Chrome Beta" chromium
install_host "$APPSUP/Google/Chrome Canary" chromium
install_host "$APPSUP/Chromium" chromium
install_host "$APPSUP/BraveSoftware/Brave-Browser" chromium
install_host "$APPSUP/Microsoft Edge" chromium

cat <<EOF

==> Done.

Load the extension (persists across restarts in Chromium browsers):

  Chrome/Brave/Edge:  open  chrome://extensions  (brave://, edge://)
                      enable "Developer mode" (top-right)
                      click "Load unpacked" -> select:
                        $EXT

  Firefox (temporary, reload after restart):
                      open  about:debugging#/runtime/this-firefox
                      "Load Temporary Add-on" -> select:
                        $EXT/manifest.json

Then play a song on music.youtube.com. The browser auto-launches the menu-bar
app; the lyric line appears in the menu bar. Re-run this script after any code
change to the app (rebuilds + refreshes host paths).
EOF
