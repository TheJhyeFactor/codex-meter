#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
OUTPUT="${1:-$ROOT/dist}"
FINAL_APP="$OUTPUT/Codex Meter.app"
FINAL_CLI="$OUTPUT/codex-meter"
STAGE="$(mktemp -d)"
APP="$STAGE/Codex Meter.app"
trap 'rm -rf "$STAGE"' EXIT

cd "$ROOT"
swift build -c release --triple arm64-apple-macosx13.0 --scratch-path "$ROOT/.build-arm64"
swift build -c release --triple x86_64-apple-macosx13.0 --scratch-path "$ROOT/.build-x86_64"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun lipo -create \
  "$ROOT/.build-arm64/arm64-apple-macosx/release/CodexMeter" \
  "$ROOT/.build-x86_64/x86_64-apple-macosx/release/CodexMeter" \
  -output "$APP/Contents/MacOS/CodexMeter"
xcrun lipo -create \
  "$ROOT/.build-arm64/arm64-apple-macosx/release/codex-meter" \
  "$ROOT/.build-x86_64/x86_64-apple-macosx/release/codex-meter" \
  -output "$STAGE/codex-meter"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

xattr -cr "$APP"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
codesign --force --sign - "$STAGE/codex-meter"

rm -rf "$FINAL_APP"
mkdir -p "$OUTPUT"
ditto --norsrc --noextattr --noqtn --noacl "$APP" "$FINAL_APP"
xattr -cr "$FINAL_APP"
codesign --force --deep --sign - "$FINAL_APP"
codesign --verify --deep --strict "$FINAL_APP"
cp "$STAGE/codex-meter" "$FINAL_CLI"
chmod 755 "$FINAL_CLI"
codesign --verify --strict "$FINAL_CLI"
echo "$FINAL_APP"
