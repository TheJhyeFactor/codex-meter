# Architecture

Codex Meter is a SwiftUI/AppKit status-bar application with six small layers:

1. `AppDelegate` owns `NSStatusItem` and `NSPopover` lifecycle.
2. `UsageStore` owns polling, preferences, login-item registration, and low-usage notifications.
3. `CodexAppServerClient` owns one local stdio JSONL session with `codex app-server`.
4. `RateLimitParser` converts versioned app-server payloads into stable UI models.
5. `LocalActivityScanner` filters aggregate-only token events from local rollout logs, deduplicates them and produces daily buckets.
6. `CodexMeterCLI` exposes stable status/history DTOs for local scripts without importing AppKit.

The client performs the required `initialize` handshake before calling `account/rateLimits/read`. It prefers the `codex` entry in the multi-bucket response and falls back to the backward-compatible single-bucket response. Percentages are clamped to 0–100, and the menu bar displays the lowest remaining percentage across returned windows.

The app intentionally does not consume rate-limit reset credits or expose any write-capable Codex method.

## Local activity

The scanner discovers recent `.jsonl` files under `~/.codex/sessions` and `~/.codex/archived_sessions`. It uses local `/usr/bin/grep` substring prefiltering before strict event-type decoding. Candidate lines briefly enter process memory; only timestamps and numeric cumulative totals are retained. Per-rollout non-negative deltas ignore repeated counters, handle resets and deduplicate archived copies through stable rollout identity plus cumulative fingerprints.

The first seven-day scan is bounded to recently modified logs. Results are cached in memory and refreshed every ten minutes, while quota checks remain on a separate two-minute schedule. No helper daemon remains running between scans.

## Cost estimates

Cached input is a subset of input, so estimates price non-cached input as `input - cached`, then apply the user-owned input, cached-input and output rates. Reasoning output is not added again because it is contained in output totals. The UI always calls the result an API-equivalent estimate.

## Distribution

Both the app and CLI are compiled for arm64 and x86_64 and merged into universal binaries. The free release is ad-hoc signed. WidgetKit is excluded until a Developer ID/App Group/notarization pipeline can preserve its capabilities reliably.
