# Changelog

## 1.5.2 - 2026-09-23

- Add a per-account browser reauthentication button and automatically open it when an expired saved login blocks switching; verify the selected email before updating the existing account, then switch and resume sessions.
- Read account worker results as a flushed UTF-8 line so inherited process pipes cannot hide the switch outcome, and report the actual account error.
- Only disable node_repl through a config override when it exists in the selected Codex Home; isolated login validation no longer fails with `invalid transport`.
- Match each open Codex CLI terminal to its persisted session before switching accounts, then reopen the same sessions automatically instead of relying on daemon-loaded threads or a single latest-session fallback.
- Detect an in-progress CLI turn from the live session log when a separate app-server still reports the previous turn, and continue it after relaunch.
- Refuse ambiguous multi-terminal switches before changing credentials, verify ownership of the current login before storing it, and reopen terminated sessions under the previous identity after a rolled-back switch.
- Resume matched sessions by exact ID and stop before changing credentials when a terminal cannot be matched.

## 1.5.1 - 2026-09-22

- Refresh saved ChatGPT credentials before switching, report invalidated OAuth sessions as a concise re-login action, and wait for validation workers to release their state database between requests.
- Write credential JSON as UTF-8 without a BOM so Codex can read switched accounts; validate the target in isolation before interrupting sessions and preserve rotated credentials.
- Isolate daemon output from account results, bound daemon waits, and prevent inherited output pipes from blocking the window dispatcher.
- Keep the account panel dismissible during operations and use mouse capture for panel dragging without a nested modal loop.
- Close the shell that directly hosted the previous Codex TUI with a successful process status so Windows Terminal removes the old tab, open managed sessions in an explicitly visible new Windows Terminal window, allow the active identity to start a fresh terminal, cap resume launches to real interactive sessions, and fall back to one `codex resume --last` when the daemon reports no loaded thread.
- Removed the destructive `codex logout` step from account enrollment and isolated each new browser login in a temporary Codex Home.
- Reauthentication now updates an existing matching email instead of creating a duplicate identity.
- Reconcile the account chooser with the newest running Codex session, using an explicit managed profile when present and `account/read` for default ChatGPT sessions so stale API selections no longer override the Gmail identity actually in use.
- Stop quota and account-usage polling for custom providers; show `∞` in the compact orb and an explicit unmonitored state in the expanded quota view.
- Fixed account switching when the daemon reports zero loaded threads, including the Windows PowerShell 5.1 empty generic-list conversion edge case.
- Replaced raw PowerShell exception dumps with concise bounded status messages that cannot cover the account cards.
- Removed keyboard focus rectangles from the glass buttons and moved focus into the flyout when it opens.
- Refined the account chooser as an independent compact glass surface, removing the leftover quota-window strip around it while keeping softer row colors and safer title spacing.
- Tightened the quota card, separated primary and secondary actions, simplified analytics tabs, added clear analytics loading/error states, and replaced the bright system scrollbar with a compact glass scrollbar.
- Inactive-account quota caches now classify five-hour and weekly windows by the server-provided duration, including a safe weekly-only fallback.

## 1.5.0 - 2026-09-22

- Added a liquid-glass identity chooser beside the orb-style control for ChatGPT subscriptions and custom provider configurations.
- Added a Start Menu launcher that opens an interactive Codex terminal with the switcher's active profile and process-only provider environment.
- Refined the identity chooser with a blurred capacity backdrop, cooler translucent glass layers, softer account-row colors, and safer title spacing around the rounded border.
- Added official browser-login enrollment for two or more ChatGPT subscription identities while keeping one global active Codex login.
- Added CurrentUser DPAPI encryption for inactive ChatGPT auth snapshots and imported custom-provider API keys; generated Codex profiles contain no plaintext secret.
- Added transactional switching with active-turn interruption, daemon restart, rollback on failure, and visible terminal relaunch for loaded sessions.
- Added quota-exhaustion handling that forks before the failed turn when possible and never feeds the quota error back to the model as an instruction.
- Added live current-account quota, timestamped inactive-account quota cache, and an explicit unknown state for custom providers.
- Preserved the absolute read-only Reset Credits boundary: account switching contains no credit redemption, consumption, or reset operation.

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
