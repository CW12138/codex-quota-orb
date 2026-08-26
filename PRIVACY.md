# Privacy

Codex Quota Orb is designed to keep usage data on the user's computer.

## Data it reads

- Quota and account usage responses exposed by the locally installed Codex app server.
- Available Reset Credits and their expiry times exposed by `account/rateLimits/read` through the locally installed Codex app server, queried only when the Reset Credits page is opened or manually refreshed.
- Local Codex session event files for fallback quota snapshots, the latest advertised Skill catalog, Skill/Agent attribution, completion markers, and already-recorded Tool calls.
- Local process metadata to detect an interactive `codex` launch.
- Local user Skill directory names and `SKILL.md` file presence for the installed-Skill inventory; Skill contents are not read by the analytics module.
- Global and project-scoped Codex `config.toml` section names for configured MCP Server and plugin counts. Secret values are neither required nor returned.

## Data it stores

The widget writes these local files under `%LOCALAPPDATA%\CodexRateWidget`:

- `settings.json`: window position and UI settings.
- `usage-cache.json`: cached local session summaries for faster analytics.
- `rate-history.jsonl`: quota snapshots observed by the widget.
- `watcher.log`: local launch-watcher diagnostics.

These files are not uploaded by the project.

## Data it does not collect

- Passwords, API keys, access tokens, or browser cookies read, stored, copied, displayed, or logged by the widget. The widget does not read `auth.json`; Codex authentication remains inside the local app server.
- Telemetry, advertising identifiers, or crash reports sent to the maintainer.
- Model prompts or responses for remote analysis. Workflow hints are fixed local rules and make no model request, so the widget itself consumes 0 model Tokens.
- Live MCP connections, health checks, tool discovery calls, or remote MCP queries. Tool analytics only summarizes local configuration and calls already present in session history.

The installer downloads project files from GitHub. At runtime, the widget communicates with the local Codex app server and local files. It does not directly call an internal ChatGPT backend endpoint or the separate card-consumption app-server method.

## Remove local data

Normal uninstall keeps local history so it can survive a reinstall. To remove it too, run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Programs\CodexQuotaOrb\Uninstall.ps1" -RemoveData
```
