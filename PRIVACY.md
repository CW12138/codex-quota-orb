# Privacy

Codex Quota Orb is designed to keep usage data on the user's computer.

## Data it reads

- Quota and account usage responses exposed by the locally installed Codex app server.
- Available Reset Credits and their expiry times from the official account service, queried only when the Reset Credits page is opened or manually refreshed.
- Local Codex session event files for fallback quota snapshots and Skill/Agent attribution.
- Local process metadata to detect an interactive `codex` launch.
- Local user Skill directory names and `SKILL.md` file presence for the installed-Skill inventory; Skill contents are not read by the analytics module.

## Data it stores

The widget writes these local files under `%LOCALAPPDATA%\CodexRateWidget`:

- `settings.json`: window position and UI settings.
- `usage-cache.json`: cached local session summaries for faster analytics.
- `rate-history.jsonl`: quota snapshots observed by the widget.
- `watcher.log`: local launch-watcher diagnostics.

These files are not uploaded by the project.

## Data it does not collect

- Passwords, API keys, access tokens, or browser cookies stored, copied, displayed, or logged by the widget. The local Codex ChatGPT access token is used only in memory for the read-only Reset Credits request.
- Telemetry, advertising identifiers, or crash reports sent to the maintainer.
- Model prompts or responses for remote analysis.

The installer downloads project files from GitHub. At runtime, the widget communicates with the local Codex installation and local files; opening the Reset Credits page also makes one authenticated read-only request to the official ChatGPT account service. It does not call the separate card-consumption endpoint.

## Remove local data

Normal uninstall keeps local history so it can survive a reinstall. To remove it too, run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Programs\CodexQuotaOrb\Uninstall.ps1" -RemoveData
```
