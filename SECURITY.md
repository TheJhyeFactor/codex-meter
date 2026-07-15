# Security policy

## Reporting a vulnerability

Please do not open a public issue for a security vulnerability. Use GitHub's private vulnerability reporting for this repository instead.

Include the affected version, reproduction steps, impact, and any suggested mitigation. Do not include access tokens, account identifiers, or raw authenticated Codex traffic.

## Security model

Codex Meter starts the local `codex app-server` process and calls only the read-only `account/rateLimits/read` method. It does not read `~/.codex/auth.json`, store credentials, add analytics, or send usage data to a separate service.

Local history scans only aggregate `token_count` records from recent Codex rollout logs. Those source files can contain private content, so the scanner prefilters exact record types, decodes a narrow numeric DTO, never logs source lines, and keeps aggregate results on the Mac.

The distributed app is built by GitHub Actions from the tagged source. Release artifacts should be verified against the source before use in sensitive environments.
