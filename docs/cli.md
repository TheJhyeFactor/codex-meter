# CLI reference

The release ZIP includes a universal `codex-meter` binary for shell scripts, Shortcuts and local alerts.

## Status

```sh
codex-meter status [--json] [--threshold 0...100]
```

Text mode prints one line per rate-limit window plus the tightest remaining value. JSON mode returns a versioned object with ISO-8601 timestamps and never exposes raw app-server data.

Exit codes:

- `0`: current data returned and above the threshold, or no threshold was supplied.
- `1`: invalid arguments, unavailable Codex data or another operational error.
- `2`: current data returned and the tightest window is at or below the supplied threshold.

## Local history

```sh
codex-meter history [--json] [--days 1...90]
                    [--input-rate N] [--cached-input-rate N] [--output-rate N]
```

History reads aggregate local token events only. Rate flags are optional USD-per-million-token values used for an API-equivalent estimate. No rate is bundled because model prices change and subscription usage is not the same as an API bill.
