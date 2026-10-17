# Hibermate

macOS menu bar app (SwiftUI, macOS 14+, universal). It keeps a MacBook awake with the lid closed **only while an AI agent (Claude Code first) is working**, then lets it sleep safely. When no agent is working, macOS must behave as if Hibermate were not installed. Free, open source, distributed as a DMG on GitHub Releases.

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
3. Never sleep a Mac someone is using. Sleep only if the lid is closed (`AppleClamshellState` via IOKit), no external display is connected, no other process holds a system-sleep assertion (`IOPMCopyAssertionsByProcess`, excluding our own), and the grace period has passed. The `.critical` rule is the only exception.
4. Hooks never interfere with Claude Code. They always exit 0, finish in under 100 ms, print nothing to stdout or stderr, never read prompts or transcripts, and work silently when Hibermate is absent.
5. No network access and no telemetry. Log locally with `os_log` only. Store only session IDs, PIDs, timestamps, event names, and the project folder name (`basename(cwd)`, never the full path).
6. Fail safe. When anything is uncertain, there is no hold and macOS sleeps normally.

## Architecture (summary)
- **App:** `MenuBarExtra`, `LSUIElement=YES`, not sandboxed. A state machine drives everything: Idle → Holding → GracePeriod → Idle, plus ForcedRelease. All transitions are idempotent. After a forced release it stays latched until the lid is reopened, thermal is nominal or fair, and the battery is above threshold + 5% or on AC. Prompts queued before the lid closes must all run: grace (min 30 s) spans the Stop → UserPromptSubmit gap.
- **Privileged helper:** an `SMAppService.daemon` with its plist embedded in the bundle. Its XPC interface has only `setSleepDisabled(Bool)` and `sleepNow()`, plus a heartbeat. It verifies the caller's code signature. A dead-man switch restores the original `SleepDisabled` after 2 min without a heartbeat. It reconciles state on start, app launch, and wake.
- **Hold mechanism:** `pmset -a disablesleep 1` (via the helper) plus an `IOPMAssertion` PreventUserIdleSystemSleep. Display sleep is never prevented.
- **Agent detection:** Claude Code hooks write `~/Library/Application Support/Hibermate/sessions/<session_id>.json`. Hook entries are merged into `~/.claude/settings.json`: back up first, tag our entries, validate, write atomically, refuse to edit a corrupt file. Optional process watching (off by default).
- The helper is registered only when the app runs from `/Applications`, never when translocated. It never holds before the user approves it in Login Items.

## Distribution
`scripts/build-dmg.sh` (xcodebuild archive/export + hdiutil) → `Hibermate-<version>.dmg` + SHA-256. Signing and notarization are switched on by env vars; credentials are never committed. A GitHub Actions workflow builds on `v*` tags and attaches the DMG to a **draft** release. Versions are SemVer, set in one place. Sparkle and the Homebrew cask are roadmap items only.

## Decisions (2026-10-17)
Bundle IDs `com.sr7d3v.hibermate` and `.helper`; GPL-3.0; unsigned (ad-hoc) releases for now (no paid Developer ID); attribution turned off in `.claude/settings.json`. Full list in [docs/PLAN.md §10](docs/PLAN.md).

## Status
- [x] Step 0: spec saved verbatim, with verification notes and decisions in SPEC Appendix A
- [x] Plan approved: [docs/PLAN.md](docs/PLAN.md)
- [x] Housekeeping: LICENSE (GPL-3.0), .gitignore, CHANGELOG.md, .claude/settings.json
- [ ] HibermateCore package (state machine, safety policy, sessions, settings merge, helper core) + unit tests
- [ ] Hook binary · helper · app UI · Xcode project · build-dmg.sh · release workflow · uninstall.sh · README · manual checklist
