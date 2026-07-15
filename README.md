<p align="center">
  <img src="docs/images/hero.svg" alt="Codex Meter — know what's left and what used it" width="100%">
</p>

<h1 align="center">Codex Meter</h1>

<p align="center"><strong>Your Codex limits, reset times, model usage and local cost estimate—right in the macOS menu bar.</strong></p>

<p align="center">No extra account. No analytics. No Electron. Just one small native Mac app doing one useful job.</p>

<p align="center">
  <a href="https://github.com/TheJhyeFactor/codex-meter/releases/latest"><img src="https://img.shields.io/badge/macOS-13%2B-17181B?logo=apple" alt="macOS 13+"></a>
  <a href="https://www.swift.org/"><img src="https://img.shields.io/badge/Swift-6-17181B?logo=swift&logoColor=white" alt="Swift 6"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-17181B" alt="MIT License"></a>
  <a href="https://github.com/TheJhyeFactor/codex-meter/releases/latest"><img src="https://img.shields.io/github/v/release/TheJhyeFactor/codex-meter?display_name=tag&sort=semver&color=087FF5" alt="Latest release"></a>
</p>

Codex Meter is a free, open-source macOS menu bar app that shows how much Codex usage you have left, when it resets, which models used it, and what that activity would cost at standard API rates.

I built this because I wanted one simple answer sitting in the menu bar: **how much Codex do I have left?** I did not want fake estimates, a web account, an Electron app or another service collecting usage data.

> Cost is always labelled as an **API-equivalent estimate**. It is not presented as your ChatGPT subscription bill.

## At a glance

| Quota | Local insight | Cost | Automation |
| --- | --- | --- | --- |
| Remaining percentage | Seven-day native chart | Official per-model rates | Universal CLI |
| Exact reset time | Model-by-model usage | USD, AUD or EUR | JSON output |
| Honest stale/error state | Prompts stay ignored | Unknown models stay unpriced | Threshold exit codes |

## Why Codex Meter is different

### Honest when data fails

If Codex cannot return a current limit, Codex Meter says it is unavailable. It never leaves a stale percentage looking current and never invents a reset estimate.

### Open enough to trust

The complete Swift source, local-log parser, build scripts and release automation are public. You can inspect exactly what the app reads and verify that it does not copy credentials or transmit local history.

### A true one-job Mac app

No Electron runtime, background helper daemon, analytics SDK or external database. The native app sleeps between quota checks and scans local activity at most every ten minutes.

### Power without a privacy trade-off

Alert thresholds, menu-bar modes, history charts, cost rates and CLI automation stay on your Mac. No separate API key or external dependency is required.

## Features

- Shows the most constrained Codex allowance directly in the macOS menu bar.
- Breaks down every available usage window with a percentage and local reset time.
- Refreshes automatically every two minutes, with manual refresh when you want it.
- Warns you when remaining usage drops below 10%, 20%, or 30%.
- Detects stale or unavailable data instead of leaving a misleading old number visible.
- Builds a seven-day token activity chart from aggregate events in local Codex session logs.
- Breaks local usage down by the actual model recorded for each Codex turn.
- Automatically calculates an API-equivalent estimate with bundled official OpenAI standard prices.
- Displays estimates in USD, AUD or EUR with a dated local ECB reference-rate snapshot.
- Adds accounts through OpenAI's secure browser login, then hot-swaps isolated Codex profiles from a dropdown.
- Deletes unused local account profiles and their saved Codex credentials with confirmation.
- Celebrates savings, token milestones and banked resets, while calling out low usage clearly.
- Switches between icon + percentage, percentage-only, icon-only and activity-chart menu-bar modes.
- Includes a universal `codex-meter` CLI with stable text/JSON output and threshold exit codes.
- Supports launch at login without adding a Dock icon.
- Keeps usage windows, activity, accounts and settings collapsible so the popover stays calm.
- Works natively on Apple silicon and Intel Macs.

## Download and install

1. Download the latest `Codex-Meter-*.zip` from [GitHub Releases](https://github.com/TheJhyeFactor/codex-meter/releases/latest).
2. Unzip it and move **Codex Meter.app** into `/Applications`.
3. Open it once. The gauge and remaining percentage will appear in your menu bar.

The ZIP also includes the optional `codex-meter` command-line tool and an installation note.

The current community build is ad-hoc signed, not Apple-notarized. If macOS blocks the first launch, Control-click the app in Finder, choose **Open**, then confirm **Open** once. The normal double-click flow works after that.

### Requirements

- macOS 13 Ventura or newer
- ChatGPT/Codex installed and signed in
- A Codex plan that returns rate-limit information

Codex Meter checks the ChatGPT app bundle and common Homebrew, npm, Volta, and local CLI locations. Developers launching from Terminal can also set `CODEX_PATH` to an absolute Codex executable path.

Codex Meter account profiles control the meter and its bundled Codex CLI session. The Codex desktop app maintains a separate login and currently exposes no supported account-switch API or deep link, so the app provides a direct handoff to switch that session inside Codex.

## Privacy by design

This app has one job and does not need your data for anything else.

- No analytics
- No ads
- No tracking
- No extra network service
- No copied or stored Codex credentials
- No uploaded session history

Codex Meter starts the local `codex app-server` process and calls its read-only `account/rateLimits/read` method. For history, it prefilters `turn_context` and `token_count` lines from local rollout logs, then a narrow decoder retains only model IDs, timestamps and cumulative numeric totals; prompts, responses and tool payload fields are ignored. It never reads `~/.codex/auth.json` and never calls the rate-limit reset action. See [Privacy](docs/privacy.md) and [Architecture](docs/architecture.md) for the full data flow.

## CLI and scripting

```sh
# Human-readable limit status
codex-meter status

# Stable JSON for Shortcuts, jq or scripts
codex-meter status --json

# Exit 2 when the tightest window reaches 20% or lower
codex-meter status --threshold 20

# Seven days of local token activity
codex-meter history --days 7 --json

# Show the model breakdown and estimates in Australian dollars
codex-meter history --days 7 --currency AUD
```

Known models are priced automatically using a bundled snapshot of official standard API rates. Optional flags provide a fallback for unknown future models:

```sh
codex-meter history --days 30 \
  --input-rate 2.00 \
  --cached-input-rate 0.50 \
  --output-rate 8.00
```

The result includes each model's token total, share, pricing status and estimate. USD is the base price; AUD and EUR conversion uses a dated [European Central Bank reference-rate snapshot](https://www.ecb.europa.eu/stats/policy_and_exchange_rates/euro_reference_exchange_rates/html/index.en.html). It is labelled **API-equivalent estimate**—not ChatGPT subscription spend. The bundled price snapshot is dated and linked to the [official OpenAI model catalogue](https://developers.openai.com/api/docs/models); long-context, regional, priority, batch, flex and tool-call adjustments are not inferred from local aggregate logs. See the full [CLI reference](docs/cli.md).

## Build it yourself

You need the macOS Swift toolchain.

```sh
git clone https://github.com/TheJhyeFactor/codex-meter.git
cd codex-meter
SKIP_LIVE_CODEX_CHECK=1 ./scripts/test.sh
./scripts/build-app.sh
open "dist/Codex Meter.app"
```

Run `./scripts/test.sh` without the environment variable when Codex is installed and signed in to include the live integration check.

## Why open source?

A usage meter should be easy to inspect and easy to trust. You can see exactly what Codex Meter runs, how it reads the percentage, what it stores, and what it does not touch.

If you find a bug or have a practical improvement, [open an issue](https://github.com/TheJhyeFactor/codex-meter/issues) or read [CONTRIBUTING.md](CONTRIBUTING.md).

## Widget status

The data layer is ready for a future macOS widget, but the public ad-hoc build does not claim WidgetKit support yet. Reliable widgets require an Apple team-bound App Group, separately signed extension and notarized distribution. Shipping a half-working widget would break the same honest-error promise this app is built around. The exact production path is documented in [Widget roadmap](docs/widget-roadmap.md).

## Project status

Codex Meter tracks the local Codex app-server interface and local rollout aggregate format. These can change between Codex versions, so compatibility fixes may be needed as Codex evolves. Errors are shown honestly rather than replaced with estimated quota data.

## License

MIT licensed. Free to use, modify, and share. See [LICENSE](LICENSE).

---

Built and maintained by [Jhye / The Jhye Factor](https://github.com/TheJhyeFactor).

> Codex Meter is an independent community project. It is not affiliated with, endorsed by, or sponsored by OpenAI. Codex and OpenAI are trademarks of their respective owners.
