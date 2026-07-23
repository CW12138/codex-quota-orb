# Changelog

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
