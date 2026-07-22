# Privacy

Codex Quota Orb is designed to keep usage data on the user's computer.

## Data it reads

- Quota and account usage responses exposed by the locally installed Codex app server.
- Local Codex session event files for fallback quota snapshots and Skill/Agent attribution.
- Local process metadata to detect an interactive `codex` launch.

## Data it stores

The widget writes these local files under `%LOCALAPPDATA%\CodexRateWidget`:

- `settings.json`: window position and UI settings.
- `usage-cache.json`: cached local session summaries for faster analytics.
- `rate-history.jsonl`: quota snapshots observed by the widget.
- `watcher.log`: local launch-watcher diagnostics.

These files are not uploaded by the project.

## Data it does not collect

- Passwords, API keys, access tokens, or browser cookies.
- Telemetry, advertising identifiers, or crash reports sent to the maintainer.
- Model prompts or responses for remote analysis.

The installer downloads project files from GitHub. The widget itself communicates only with the local Codex installation and local files, although Codex may contact OpenAI as part of its normal authenticated operation.

## Remove local data

Normal uninstall keeps local history so it can survive a reinstall. To remove it too, run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Programs\CodexQuotaOrb\Uninstall.ps1" -RemoveData
```
