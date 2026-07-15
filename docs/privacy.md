# Privacy

Codex Meter is designed so useful monitoring does not require another monitoring service.

## What the app reads

- Current rate-limit data through the local, read-only Codex app-server interface.
- Model IDs from `turn_context` records and aggregate `token_count` events in recently modified files under `~/.codex/sessions` and `~/.codex/archived_sessions`.
- Local preferences for alert thresholds, display mode, currency, custom fallback rates and launch at login.
- Account profile directories created under `~/.codex-meter/accounts`; Codex owns their credentials and Codex Meter never reads them.

## What the app deliberately ignores

Rollout logs can contain private prompts, responses, tool calls and file paths. The history scanner uses a local filter to reduce candidate lines, then decodes narrow structures containing only the exact event discriminator, bounded model ID, timestamp and numeric token totals. Candidate lines exist briefly in process memory, but unknown fields are never retained in models, logs, history or errors.

## What leaves the Mac

Codex Meter has no analytics, telemetry, advertising, account service or history upload. The quota request is handled by the installed Codex process using its existing session. Local history, model pricing and USD/AUD/EUR conversion do not make network calls.

Adding an account starts the supported `codex login` browser flow with a profile-specific `CODEX_HOME`. Email, password, SSO and MFA are entered only on OpenAI's secure page; the browser returns the completed session directly to Codex. Codex Meter then starts the read-only app-server under that profile. The app does not copy, parse or display `auth.json`, access tokens, passwords or verification codes.

## Cost estimates

ChatGPT subscriptions are not billed as a simple per-token API invoice. Codex Meter therefore does not claim to show money spent. It applies a bundled, dated snapshot of official standard API prices entirely offline. Custom fallback rates for unknown models remain in local preferences. No local usage is sent to OpenAI's pricing pages.
