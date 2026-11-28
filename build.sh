#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")" && pwd)"
build_dir="${1:-$project_dir/build}"
app="$build_dir/StudioPortal.app"
node="${SKETCHFAB_NODE:-$(command -v node)}"
if [[ -e "$app" ]]; then
  printf 'Das Ziel existiert bereits: %s\n' "$app" >&2
  exit 1
fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Lizenzen"
cp "$project_dir/src/Info.plist" "$app/Contents/Info.plist"
cp "$project_dir/src/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
cp "$project_dir/ARCHITEKTUR.md" "$app/Contents/Resources/ARCHITEKTUR.md"
cp "$project_dir/src/download.mjs" "$project_dir/src/providers.mjs" "$project_dir/src/from_images.mjs" "$project_dir/src/meta.mjs" "$project_dir/src/convert.py" "$app/Contents/Resources/"
cp "$project_dir/src/livekit_phone_agent.py" "$project_dir/src/livekit_web_bridge.py" "$app/Contents/Resources/"
cp "$project_dir/src/web-search.mjs" "$project_dir/src/pi-permissions.mjs" "$project_dir/src/pi-photocraft-save.mjs" "$project_dir/src/photocraft-stdio.mjs" "$project_dir/src/photocraft-retouch.mjs" "$app/Contents/Resources/"
cp "$project_dir/src/Node-LICENSE.txt" "$app/Contents/Resources/Lizenzen/Node.txt"
ditto "$project_dir/vendor/sfrip" "$app/Contents/Resources/sfrip"
if lipo -info "$node" | grep -q 'Non-fat file'; then
  cp "$node" "$app/Contents/Resources/node"
else
  lipo "$node" -thin arm64 -output "$app/Contents/Resources/node"
fi
chmod 755 "$app/Contents/Resources/node"
swiftc -O -parse-as-library -target arm64-apple-macos15.0 -o "$app/Contents/MacOS/StudioPortal" "$project_dir"/src/*.swift
# A stable identity keeps macOS privacy grants (Downloads, removable volumes) across updates; ad-hoc signing
# changes the code hash on every build and makes macOS ask again. Falls back to ad-hoc without a certificate.
identity="${STUDIOPORTAL_SIGN:-$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ {print $2; exit}')}"
identity="${identity:--}"
codesign --force --sign "$identity" "$app/Contents/Resources/node"
codesign --force --deep --sign "$identity" "$app"
codesign --verify --deep --strict "$app"
printf 'Erstellt: %s\n' "$app"
