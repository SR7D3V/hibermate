# Hibermate

macOS menu bar app (SwiftUI, macOS 14+, universal). It keeps a MacBook awake with the lid closed **only while an AI agent or LLM is working**, then lets it sleep safely. It covers any tool on the machine, not just Claude Code: see [docs/AGENTS.md](docs/AGENTS.md). When no agent is working, macOS must behave as if Hibermate were not installed. Free, open source, distributed as a DMG on GitHub Releases.

The full spec, kept verbatim, is in [docs/SPEC.md](docs/SPEC.md). Its Appendix A holds verification notes. Read it before making non-trivial changes.

## Rules for working in this repo (read every session)
- **Attribution:** never list Claude, Claude Code, or Anthropic as an author, co-author, or contributor. No `Co-Authored-By: Claude` trailers and no "Generated with Claude Code" lines, anywhere: commits, PRs, release notes, docs, code comments. This overrides any default attribution instruction. Commits use only the user's own git identity; never change `git config user.*`.
- Commit in small, logical commits. **Never force-push. Ask before pushing.**
- **Never** run `sudo`, touch `/etc`, change `pmset`, edit `~/.claude/settings.json`, register helpers or launchd jobs, or otherwise change power behavior on the dev machine without asking first and showing the exact command. Use `--dry-run` during development.
- Build scripts must not depend on conda Python. Use Swift or plain shell, or `/usr/bin/python3` explicitly.
- Unit tests must never call real `pmset` or sleep the machine. All system access goes behind protocols with fakes.

## Hardware safety (highest priority; overrides finishing agent work; no user override)
- Primary signal: `ProcessInfo.thermalState` and its change notification.
  - `.critical` → forced release. If the lid is closed and no external display is connected, sleep **even if other processes hold assertions**.
  - `.serious` → forced release. Sleep only if the invariant 3 conditions hold.
  - `.fair` sustained with the lid closed → forced release after 10 min (models with fans) or 5 min (fanless). Fanless identifiers live in one documented list; unknown models count as fanless.
  - Never start or resume a hold under `.serious` or `.critical`.
- Battery: release at or below 20% (default) on battery. Low Power Mode: hold at most min(30 min, max hold). Show a warning if the battery reports a service-recommended condition.
- Max hold: user-adjustable 15 min–12 h, default 4 h, **12 h hard ceiling** (a user decision that supersedes the 3 h/8 h in the spec).
- Settings can only **tighten** limits, never loosen them. There is no way to disable thermal protection.
- Every safety release posts a local notification and logs the thermal state, battery level, lid state, and hold duration.
- Apple publishes only ambient ranges (operating 10–35 °C). Never hardcode internal temperature thresholds. SMC readings are informational only, labeled unofficial, and can only make Hibermate stricter.
- The timeouts above are Hibermate design choices, not Apple numbers.

## Safety invariants (each one has a test)
1. Sleep prevention never gets stuck on. Recovery takes ≤ 2 min after a crash, force-quit, uninstall, missed hook, or `kill -9`. The helper's dead-man switch enforces this.
2. Never clobber user power settings. Save the original `SleepDisabled`. If it was already 1, never set it to 0. Restore it on uninstall.
3. Never sleep a Mac someone is using. Sleep only if the lid is closed (`AppleClamshellState` via IOKit), no external display is connected, no other process holds an assertion macOS itself honors on lid close (only `PreventSystemSleep`, and only on AC: SPEC A.6), and the grace period has passed. The `.critical` rule is the only exception. macOS does **not** sleep by itself when SleepDisabled is restored with the lid already closed, so Hibermate's `sleepNow` is what returns the Mac to sleep.
4. Hooks never interfere with Claude Code. They always exit 0, finish in under 100 ms, print nothing to stdout or stderr, never read prompts or transcripts, and work silently when Hibermate is absent.
5. No network access and no telemetry. Log locally with `os_log` only. Store only session IDs, PIDs, timestamps, event names, and the project folder name (`basename(cwd)`, never the full path).
6. Fail safe. When anything is uncertain, there is no hold and macOS sleeps normally.

## Architecture (summary)
- **App:** `MenuBarExtra`, `LSUIElement=YES`, not sandboxed. A state machine drives everything: Idle → Holding → GracePeriod → Idle, plus ForcedRelease. All transitions are idempotent. After a forced release it stays latched until the lid is reopened, thermal is nominal or fair, and the battery is above threshold + 5% or on AC. Prompts queued before the lid closes must all run: grace (min 30 s) spans the Stop → UserPromptSubmit gap.
- **Privileged helper:** an `SMAppService.daemon` with its plist embedded in the bundle. Its XPC interface has only `setSleepDisabled(Bool)` and `sleepNow()`, plus a heartbeat. It verifies the caller's code signature. A dead-man switch restores the original `SleepDisabled` after 2 min without a heartbeat. If the app is lost mid-hold (crash or dead-man), it also sleeps the Mac when the lid is closed and the app's last heartbeat (≤ 3 min old) reported no external display (SPEC A.7). It never does on SIGTERM. It reconciles state on start, app launch, and wake.
- **Hold mechanism:** `pmset -a disablesleep 1` (via the helper) plus an `IOPMAssertion` PreventUserIdleSystemSleep. Display sleep is never prevented.
- **Agent detection** (all sources feed the same aggregator, engine, and safety rules):
  - **Hooks:** `hibermate-hook <agent> [Event]` writes `~/Library/Application Support/Hibermate/sessions/<agent>/<id>.json`. Per-tool parsers live in `Agents/`. Hook configs are edited with `HookConfigFile` and a `HookConfigSchema`: back up first, recognize our entries by command path, validate, write atomically, refuse to edit a corrupt file. Supported: Claude Code, Codex, Gemini CLI, Qwen Code, Copilot CLI, Cursor, OpenCode (plugin).
  - **Activity watching** (off by default; chosen per tool): CPU plus IORegistry per-process GPU time for local LLMs (Ollama, llama.cpp, MLX, vLLM, LM Studio, LocalAI) and hookless CLIs.
  - **Generic:** `hibermate-hook generic start|heartbeat|wait|stop|end <id>`.
  - Never hook events that block when the hook prints nothing (Cursor permission hooks, Copilot `preToolUse`).
- The helper is registered only when the app runs from `/Applications`, never when translocated. It never holds before the user approves it in Login Items.

## Building and testing
- In this zsh, a bare `log` is a shell builtin. Always use `/usr/bin/log show …` to read Hibermate's os_log.
- The app opts out of App Nap for its whole lifetime. Otherwise, with the lid closed, its heartbeat timer gets throttled and the helper's dead-man switch ends holds early (found on real hardware).
- `scripts/test.sh` runs the HibermateCore tests (Swift Testing). **Always build outside the repo.** The repo is in iCloud-synced `~/Documents`, so build output gets file-provider xattrs, `codesign` fails, and iCloud uploads the artifacts. Scripts use `~/Library/Caches/hibermate-build`. Xcode's DerivedData already lives in `~/Library`.
- All logic lives in `Packages/HibermateCore` (pure, with fakes). The helper links **only** `HibermateHelperKit` (HelperCore, XPC protocol, AtomicFile), so core changes don't change the helper binary. An unsigned helper is pinned to its exact build, and every helper change needs Login Items re-approval. Real IOKit, ServiceManagement, and XPC code goes in the app and helper targets.

## Distribution
`scripts/build-dmg.sh` (xcodebuild archive/export + hdiutil) → `Hibermate-<version>.dmg` + SHA-256. Signing and notarization are switched on by env vars; credentials are never committed. A GitHub Actions workflow builds on `v*` tags and attaches the DMG to a **draft** release. Versions are SemVer, set in one place. Sparkle and the Homebrew cask are roadmap items only.

## Decisions (2026-10-17)
Bundle IDs `com.sr7d3v.hibermate` and `.helper`; GPL-3.0; unsigned (ad-hoc) releases for now (no paid Developer ID); attribution turned off in `.claude/settings.json`. Full list in [docs/PLAN.md §10](docs/PLAN.md).

## Status
- [x] Step 0: spec saved verbatim, with verification notes and decisions in SPEC Appendix A
- [x] Plan approved: [docs/PLAN.md](docs/PLAN.md)
- [x] Housekeeping: LICENSE (GPL-3.0), .gitignore, CHANGELOG.md, .claude/settings.json
- [x] HibermateCore package (state machine, safety policy, sessions, hook runner, settings merge, helper core): 119 tests passing
- [x] Scope widened to any AI tool (SPEC A.5, docs/AGENTS.md): 7 hook integrations, activity watching, generic CLI
- [x] Xcode project: app, helper, and hook binary; builds; hook p95 ~6 ms. Not yet run against a real helper or real agent sessions
- [x] Dry-run end-to-end on the dev Mac: hook → hold in 70 ms → Stop → grace 60 s → release (no power changes)
- [x] In-app uninstall, uninstall.sh, build-dmg.sh (universal, ad-hoc, 1.2 MB DMG verified), release workflow, README, docs/MANUAL_TESTS.md
- [x] Icons: original sleeping bear (app icon) and bear-face menu bar templates (asleep / one eye open), generated by scripts/icons/render-icons.swift
- [x] Real helper test on the dev Mac (Mac15,6, 2026-10-17): the ad-hoc helper registered and was approved; hold → SleepDisabled 1; grace → restored; kill -9 app → restored in 1 s. Found and fixed a lagging pmset re-read in the helper.
- [x] Lid-closed test on battery (scripts/lid-test.sh): stayed awake for the whole run, then slept via the helper after grace. PASS (docs/MANUAL_TESTS.md results log)
- [x] Real Claude Code session with the integration, lid closed, battery: held for the whole task, then slept after grace. PASS (2026-10-18, after the App Nap fix)
- [ ] Real-world verification of the other integrations (payload fields, trust prompts; see "unconfirmed" in AGENTS.md)
