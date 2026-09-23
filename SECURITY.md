# Security policy

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting for this repository when available. Do not open a public issue containing credentials or private Codex data.

When reporting a bug, never attach:

- Files from `.codex/sessions`.
- `usage-cache.json`, `rate-history.jsonl`, or `watcher.log`.
- `%LOCALAPPDATA%\CodexRateWidget\accounts`, `accounts.json`, or any `*.dpapi` credential vault file.
- Codex `auth.json` or generated `cqo-*.config.toml` profiles.
- Access tokens, API keys, browser cookies, or screenshots that expose account details.

Account-switcher secrets are protected with Windows CurrentUser DPAPI. They can only be decrypted by the same Windows user profile on the same machine. The active ChatGPT credential still follows Codex's own local `auth.json` storage behavior. Rotate any API key that has ever been pasted into a chat, issue, log, or screenshot.

A minimal reproduction, redacted error message, Windows version, PowerShell version, Codex CLI version, and Python version are usually sufficient.
