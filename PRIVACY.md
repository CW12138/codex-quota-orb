# Privacy

Codex Quota Orb is designed to keep usage data on the user's computer.

## Data it reads

- Quota and account usage responses exposed by the locally installed Codex app server.
- Available Reset Credits and their expiry times exposed by `account/rateLimits/read` through the locally installed Codex app server, queried only when the Reset Credits page is opened or manually refreshed.
- Local Codex session event files for fallback quota snapshots, the latest advertised Skill catalog, Skill/Agent attribution, completion markers, and already-recorded Tool calls.
- Local process metadata to detect an interactive `codex` launch.
- Local user Skill directory names and `SKILL.md` file presence for the installed-Skill inventory; Skill contents are not read by the analytics module.
- Global and project-scoped Codex `config.toml` section names for configured MCP Server and plugin counts. Secret values are neither required nor returned.
- When explicitly using account switching, the active Codex `auth.json` needed to register and restore ChatGPT subscription identities.
- When explicitly importing a custom provider, the selected `auth.json` API key and the provider/model fields from its companion `config.toml`.
- Loaded local thread metadata and recent turns needed to interrupt, fork, and visibly resume sessions during a global identity change. A detected quota-failure message is classified locally and is not reused as a continuation instruction.

## Data it stores

The widget writes these local files under `%LOCALAPPDATA%\CodexRateWidget`:

- `settings.json`: window position and UI settings.
- `usage-cache.json`: cached local session summaries for faster analytics.
- `rate-history.jsonl`: quota snapshots observed by the widget.
- `watcher.log`: local launch-watcher diagnostics.
- `accounts/accounts.json`: non-secret identity labels, kinds, profile names, and last-known quota timestamps.
- `accounts/vault/*.dpapi`: inactive ChatGPT auth snapshots and custom-provider API keys encrypted with Windows DPAPI for the current Windows user.
- `resume/*.txt`: short-lived continuation prompts; each file is deleted by the resume helper after reading.

The generated `$CODEX_HOME/cqo-*.config.toml` profile files contain provider settings and environment-variable names, but not API keys. The selected ChatGPT identity is restored to Codex's normal active `auth.json`; only one ChatGPT login is active at a time.

These files are not uploaded by the project.

## Data it does not collect

- Passwords or browser cookies. Credentials handled by the opt-in switcher are never displayed or logged, and inactive copies are never stored as plaintext by this project.
- Telemetry, advertising identifiers, or crash reports sent to the maintainer.
- Model prompts or responses for telemetry or remote analysis. Passive monitoring and workflow hints make no model request. During an explicit identity switch, an interrupted task may be resumed through Codex using its original user request plus a fixed local continuation instruction; this is normal task usage under the selected identity.
- Live MCP connections, health checks, tool discovery calls, or remote MCP queries. Tool analytics only summarizes local configuration and calls already present in session history.

The installer downloads project files from GitHub. At runtime, the widget communicates with the local Codex CLI/app server and local files. Browser authentication is performed by the official `codex login` flow. The widget does not directly call an internal ChatGPT backend endpoint or the separate card-consumption app-server method.

## Remove local data

Normal uninstall keeps local history so it can survive a reinstall. To remove it too, run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Programs\CodexQuotaOrb\Uninstall.ps1" -RemoveData
```

`-RemoveData` also removes the generated `cqo-*.config.toml` profiles recorded in the account registry. It does not delete Codex's own active `auth.json`.
