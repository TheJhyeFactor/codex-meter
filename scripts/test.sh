#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

swiftc \
  "$ROOT/Sources/CodexMeterCore/RateLimitModels.swift" \
  "$ROOT/Tests/ParserCheck.swift" \
  -o "$TMP/parser-check"
"$TMP/parser-check"

swiftc \
  "$ROOT/Sources/CodexMeterCore/LocalActivity.swift" \
  "$ROOT/Tests/ActivityCheck.swift" \
  -o "$TMP/activity-check"
"$TMP/activity-check"

if [[ "${SKIP_LIVE_CODEX_CHECK:-0}" != "1" ]]; then
  swiftc \
    "$ROOT/Sources/CodexMeterCore/RateLimitModels.swift" \
    "$ROOT/Sources/CodexMeterCore/CodexAppServerClient.swift" \
    "$ROOT/Tests/LiveCheck.swift" \
    -o "$TMP/live-check"
  "$TMP/live-check"
fi

swift build --package-path "$ROOT"
"$ROOT/.build/debug/codex-meter" --help >/dev/null
"$ROOT/.build/debug/codex-meter" history --days 1 --json >/dev/null

set +e
"$ROOT/.build/debug/codex-meter" history --days 0 >/dev/null 2>&1
INVALID_EXIT=$?
set -e
if [[ "$INVALID_EXIT" -ne 1 ]]; then
  echo "Expected invalid CLI arguments to exit 1" >&2
  exit 1
fi

for BAD_ARGS in \
  "history --input-rate 2 --input-rate nope" \
  "history --input-rate nan" \
  "history --days --json"
do
  set +e
  "$ROOT/.build/debug/codex-meter" ${(z)BAD_ARGS} >/dev/null 2>&1
  BAD_EXIT=$?
  set -e
  if [[ "$BAD_EXIT" -ne 1 ]]; then
    echo "Expected bad CLI options to exit 1: $BAD_ARGS" >&2
    exit 1
  fi
done
