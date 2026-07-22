<p align="center">
  <img src="assets/orb.png" alt="Codex Quota Orb" width="112">
</p>

<h1 align="center">Codex Quota Orb</h1>

<p align="center"><strong>A native Windows floating orb for live Codex quota, daily token trends, and local Skill/Agent analytics.</strong></p>

<p align="center">
  <img src="assets/codex-quota-orb.png" alt="Codex Quota Orb preview" width="420">
</p>

Codex Quota Orb is a lightweight, local-first Windows widget. Its liquid orb shows the remaining Codex weekly quota at a glance; click it to open quota details and local usage analytics.

> [!NOTE]
> Community project. Not affiliated with or endorsed by OpenAI. Codex interfaces can change, so a future Codex update may require a widget update.

## Highlights

- Live weekly quota from the local Codex app server, with session-event fallback.
- Daily account token trends when the account usage interface is available.
- Local Skill and Agent attribution, with coverage shown explicitly.
- Floating liquid-glass orb, expandable panel, drag support, and system tray controls.
- No telemetry, ads, analytics service, or model calls.
- Runs as native PowerShell/WPF; Python is only needed for the optional analytics page.

## Install

### One command

Open PowerShell and run:

```powershell
irm https://raw.githubusercontent.com/CW12138/codex-quota-orb/main/Install.ps1 | iex
```

The installer downloads this repository, copies the runtime files to `%LOCALAPPDATA%\Programs\CodexQuotaOrb`, adds a Start Menu shortcut, enables launch detection for interactive `codex` sessions, and starts the widget. It does not require administrator rights.

Prefer to inspect scripts before running them? Download or clone the repository, review `Install.ps1`, and then double-click `Install.cmd`.

### Requirements

- Windows 10 or Windows 11.
- Codex CLI installed and signed in.
- Windows PowerShell 5.1 or later.
- Python 3.10+ on `PATH` for the 7-day, Skill, and Agent analytics pages. The quota orb works without Python.

## Use

- Click the orb to expand quota details.
- Drag the orb to move it.
- Select **View usage analytics** for 7-day, Skill, and Agent views.
- Use **—** to collapse back to the orb.
- Use the system tray icon to open, refresh, or exit.

To start it manually, open **Codex Quota Orb** from the Start Menu or run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CodexRateWidget.ps1
```

## What the numbers mean

- **Weekly quota** comes from `account/rateLimits/read` when available. It is not estimated from raw tokens.
- **Daily tokens** come from `account/usage/read.dailyUsageBuckets` when available, with local session-event fallback.
- **Skill attribution** is turn-based: single Skill, multiple Skills, and unattributed turns remain separate. Multi-Skill turns are not split using arbitrary weights.
- **Agent attribution** uses local thread metadata and always keeps the main Agent separate.
- Account-level daily usage may include other Codex surfaces or devices. Local Skill/Agent data only covers sessions found on this computer, so the two views intentionally use different denominators.

## Privacy

Codex Quota Orb is local-first:

- It reads quota through the locally installed Codex app server and reads local Codex session files for fallback and attribution.
- It does not read, display, or store access tokens.
- It sends no widget telemetry and makes no model-generation requests.
- Runtime data stays under `%LOCALAPPDATA%\CodexRateWidget`.

See [PRIVACY.md](PRIVACY.md) for the exact data boundary.

## Uninstall

Open **Uninstall Codex Quota Orb** from the Start Menu, or run the installed `Uninstall.cmd`. Usage history is kept by default. To remove local widget data as well:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Programs\CodexQuotaOrb\Uninstall.ps1" -RemoveData
```

## Development

Run a non-account UI render:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CodexRateWidget.ps1 `
  -QARenderPath .\preview.png -QAView capacity -QARemaining 64
```

Run the headless probe and Python syntax check:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CodexRateWidget.ps1 -HeadlessProbe
python -m py_compile .\UsageAnalytics.py
```

## 中文说明

Codex Quota Orb 是一个 Windows 原生、本地优先的 Codex 额度悬浮窗。水球显示周额度剩余百分比，点击后可查看额度详情、近 7 日 Token，以及本机 Skill/Agent 归因统计。

- 一行命令安装，无需管理员权限。
- 主额度页不依赖 Python；统计页需要 Python 3.10+。
- 不上传会话内容，不读取或显示访问令牌，不调用模型生成。
- 本地归因是透明的辅助统计，不伪装成官方精确计费。

## License

[MIT](LICENSE)
