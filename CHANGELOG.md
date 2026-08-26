# Changelog

## 1.4.0 - 2026-08-26

- Replaced the single-folder Skill count with a combined installed inventory and the latest locally observed Codex available-Skill catalog, including system, plugin, personal, and project scopes.
- Made repeated participating-Token attribution the primary Skill measure while retaining exclusive terminal-Skill fields and unique attribution coverage.
- Renamed route logic to multi-Skill call chains and preserved genuine chains of any observed length.
- Kept quota and Token views first, then simplified workflow navigation to Token, Skill, Agent, and Tool.
- Added readable Skill activity states and recent-use dates plus Agent completed-Turn, Tool, failure, and recent-use fields.
- Replaced the narrow MCP page with read-only Tool categories covering commands, file edits, web, Agent coordination, media, documents, workflow controls, and MCP/connectors.
- Added at most three deterministic local workflow hints without model generation.
- Added regression checks that keep the analytics module free of network, model-client, and subprocess calls, preserving 0 Token consumption by the widget itself.

## 1.3.1 - 2026-07-29

- Replaced the generic information tray glyph with a simplified half-full blue water orb matching the floating UI.
- Fixed the orb becoming unresponsive when recent Codex JSONL sessions contain very large tool-result records.
- Replaced `Get-Content -Tail` with a byte-bounded random-access tail reader.
- Moved session fallback reads and usage analytics off the WPF dispatcher into supervised child processes.
- Added worker timeouts, concurrent pipe draining, and a UI-responsiveness regression test.
- Added a compact icon-only Classic/Gradient switch to the expanded quota view with immediate, persisted style changes.
- Reserved the compact orb for 5-hour quota and split the quota view into consistent 5-hour and 1-week modules.
- Added duration-based window selection, weekly fallback while 5-hour quota is unavailable, and per-window reset timestamps.
- Moved Reset Credits reads to `account/rateLimits/read.rateLimitResetCredits` and removed direct `auth.json` and internal backend access.

## 1.3.0 - 2026-07-23

- Added an optional Gradient orb style with six continuously interpolated quota anchors from blue at 100% to orange at 0%.
- Added adaptive two-layer number contrast and a synchronized 600 ms water/color transition for the Gradient style.
- Preserved the original non-gradient Classic style as the default.
- Added `-OrbStyle Classic|Gradient` installation and launch selection.
- Added separate Classic and Gradient GitHub release packages without changing the existing v1.2.0 release.
- Added standalone Codex executable discovery alongside the existing npm layout detection.

## 1.2.0 - 2026-07-22

- Added a read-only Reset Credits page showing the available count and each local expiry time.
- Added on-entry lookup, manual retry, explicit empty/error states, and earliest-expiry-first ordering.
- Removed the quota-source hint line and placed the Reset Credits entry below usage analytics.
- Kept reset consumption and credit-purchase actions outside the widget.

## 1.1.1 - 2026-07-22

- Refined the bilingual system-font stack for cleaner Latin and Simplified Chinese rendering.
- Kept safe Windows fallbacks when preferred interface fonts are unavailable.

## 1.1.0 - 2026-07-22

- Added an installed-Skill inventory, including zero-use Skills.
- Added exclusive terminal-Skill token attribution and non-additive associated Token totals.
- Added ordered route-chain views such as `task-router → data-analysis` without double-counting chain Token totals.
- Reworked Skill and route rows into larger two-line layouts with full-width progress bars.
- Rejected bulk Skill catalogs and PowerShell variable scopes as attribution evidence.

## 1.0.0 - 2026-07-22

- Added the liquid-glass quota orb and expandable quota panel.
- Added account daily usage plus local Skill and Agent attribution views.
- Added local caching, rate history, Codex launch detection, and system tray controls.
- Added a no-admin installer, uninstaller, privacy documentation, and automated checks/releases.
