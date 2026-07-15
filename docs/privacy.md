# Privacy

Codex Meter is designed so useful monitoring does not require another monitoring service.

## What the app reads

- Current rate-limit data through the local, read-only Codex app-server interface.
- Aggregate `token_count` events in recently modified files under `~/.codex/sessions` and `~/.codex/archived_sessions`.
- Local preferences for alert thresholds, display mode, custom cost rates and launch at login.

## What the app deliberately ignores

Rollout logs can contain private prompts, responses, tool calls and file paths. The history scanner uses a local substring filter to reduce candidate lines, then decodes a narrow structure containing only the exact event discriminator, timestamp and numeric token totals. Candidate lines exist briefly in process memory, but unknown fields are never retained in models, logs, history or errors.

## What leaves the Mac

Codex Meter has no analytics, telemetry, advertising, account service or history upload. The quota request is handled by the installed Codex process using its existing session. Local history and cost calculations do not make network calls.

## Cost estimates

ChatGPT subscriptions are not billed as a simple per-token API invoice. Codex Meter therefore does not claim to show money spent. If you enter custom input, cached-input and output rates, it shows an API-equivalent estimate and keeps those rates in local preferences.
