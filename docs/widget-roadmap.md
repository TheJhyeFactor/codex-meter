# macOS widget roadmap

WidgetKit is intentionally gated behind a production signing path rather than being advertised as a half-working feature.

## Required architecture

1. Add an Xcode macOS Widget Extension target alongside the SwiftPM core library.
2. Give the app and widget a registered Apple App Group.
3. Have the host app write a tiny snapshot containing remaining percentage, reset date, sampled-at time and explicit unavailable/stale/error state.
4. Keep Codex querying, local-log parsing and notifications out of the extension.
5. Sign the extension and containing app with the same Developer ID team, enable hardened runtime, notarize and staple the release.

The current ad-hoc community build cannot reliably preserve team-bound App Group capabilities. The widget will ship when the release pipeline can meet the same trust and error-handling standard as the menu-bar app.
