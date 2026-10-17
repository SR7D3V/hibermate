# Handoff: Building "Hibermate", a macOS menu bar app

This is a handoff from a planning conversation that took place outside this tool. It contains all the context and decisions made so far. Please read all of it before doing anything.

## Step 0: Preserve this context (do this first)
1. Save this entire prompt verbatim to `docs/SPEC.md` in the repo.
2. Create a concise `CLAUDE.md` at the repo root summarizing the project, the hardware safety rules, the other safety invariants, the architecture, the distribution plan, the attribution rules, and the current status, so future sessions start with the right context. Keep it updated as the project progresses.
3. Read the current Claude Code hooks documentation (https://docs.claude.com/en/docs/claude-code/hooks) and confirm the exact hook event names, the JSON each hook receives on stdin, and how exit codes and stdout are handled. Do not rely on memory; the API may have changed. Note anything that differs from this spec.
4. Re-check Apple's temperature guidance (https://support.apple.com/102336 and the current MacBook Air and MacBook Pro tech specs pages) and note in `docs/SPEC.md` if anything differs from the "Hardware safety" section below.
5. Produce a written plan (architecture, file layout, state machine, safety rules, distribution, test plan) and wait for my approval before writing any app code.

## Decisions still open (ask me; do not decide yourself)
- **GitHub username** for the bundle ID.
- **License:** MIT (permissive; anyone can use, modify, or sell, keeping the copyright notice) or GPL-3.0 (anyone can use and modify, but distributed derivatives must also be GPL; this is what Vorssaint uses).
- **Code signing for releases:** Apple Developer ID + notarization (paid Apple Developer Program) or unsigned builds. See the Distribution section.

## Background and motivation
People running long AI agent sessions (Claude Code, Codex, etc.) on MacBooks have to keep the lid open, because closing it puts the Mac to sleep and pauses the agent. A Mac cannot run processes while truly asleep, so the real solution is: keep the Mac awake with the lid closed (display off) only while an agent is working, then put it to sleep safely once the work is done.

## Existing tools (know the competition; do not copy their code)
- **Vigil**: a menu bar app that keeps a MacBook awake with the lid closed while Claude Code, Codex, and other agents work, using Claude Code hooks, then sleeps the Mac when done. It has iPhone notifications and usage meters. It does not appear to be open source.
- **Hold My Lid**: a paid, proprietary app with agent-driven wake locks and lifecycle hooks for Claude Code, Codex, and OpenCode.
- **Vorssaint**: a free, open-source (GPLv3) all-in-one macOS menu bar toolkit with a closed-lid Keep Awake mode, but it is not agent-aware. It's distributed as a DMG on GitHub Releases; Hibermate follows the same distribution model.

**Hibermate's angle:** free, open source, agent-aware, and the most careful about hardware safety (thermal and battery cutoffs, crash-safe recovery, never clobbering user settings, never disrupting the user's workflow).

## Project identity
- **Name:** Hibermate (a pun on "hibernate" + "mate": your mate who stays up so your Mac can rest).
- **Repo name:** `hibermate` (lowercase). It's already created on GitHub and connected locally as `origin`, branch `main`. It currently contains only a README with "# Hibermate".
- **Bundle ID:** `com.<my-github-username>.hibermate`. The helper uses a related ID, e.g. `com.<username>.hibermate.helper`.
- **GitHub description:** "Keep your MacBook awake with the lid closed while Claude Code and other AI agents work, then let it sleep safely when they're done."
- **Tagline for the README:** "Close the lid. Your agents keep working."
- **GitHub topics:** macos, menu-bar-app, swiftui, claude-code, ai-agents, caffeinate, sleep-prevention, clamshell, developer-tools.
- **Icon idea:** a sleepy bear with one eye open (hibernation theme). It needs both a full-color app icon and a small monochrome menu bar template image.
- The name "hibermate" is free on Homebrew (`brew search` returned nothing), so a future cask can be named `hibermate`.

## Repo housekeeping to do early
- **LICENSE:** after I choose (see "Decisions still open").
- **.gitignore** for Swift/Xcode: `.DS_Store`, `DerivedData/`, `build/`, `dist/`, `xcuserdata/`, `*.xcuserstate`, `.swiftpm/`, `*.dmg`, plus any other build outputs your scripts create.
- **README** with: what it does, install steps (download the DMG from Releases → drag to Applications → open → approve the helper in Login Items), how it works, exactly what it changes on the system, the hardware safety behavior, how to verify it is fully off (`pmset -g | grep SleepDisabled`), known limitations, a roadmap, and uninstall instructions.
- **CHANGELOG.md** from the start.
- Commit in small, logical commits with clear messages. Never force-push. Ask before pushing.

## Ground rules for you (Claude Code) while developing
- Never run `sudo`, modify `/etc`, change `pmset` settings, edit `~/.claude/settings.json`, register helpers or launchd jobs, or do anything that changes system power behavior on my machine without first asking me and showing the exact command.
- Use the `--dry-run` mode (described below) during development.
- My terminal has a conda `(base)` environment active. Don't let build scripts depend on conda's Python; prefer Swift or plain shell, or `/usr/bin/python3` explicitly if Python is truly needed.

## Attribution
- Do not list Claude, Claude Code, or Anthropic as an author, co-author, or contributor anywhere in this project.
- No `Co-Authored-By: Claude` trailers in commit messages, and no "Generated with Claude Code" lines in commits, PR descriptions, release notes, the README, code comments, file headers, or docs.
- Commits are authored only by my own git identity (`git config user.name` / `user.email`). Never change those values.
- Claude Code adds a co-author trailer to commits by default. Check the current Claude Code settings docs for the option that turns this off (at the time of writing it was a setting like `includeCoAuthoredBy` or an `attribution` setting). Ask me before adding it to the project's `.claude/settings.json` so it's enforced for every session, not just remembered.

## Goal
When I close my MacBook lid while Claude Code (or another supported agent) is working, the Mac stays awake with the display off until the work finishes, then goes to sleep as if I had just closed the lid normally. When no agent is working, macOS behaves exactly as it would without Hibermate installed. Users install it from a DMG on GitHub Releases, and it runs from the menu bar.

## Hardware safety: the highest priority, above everything else
Protecting the Mac always beats finishing the agent's work. If any rule in this document conflicts with keeping an agent running, hardware safety wins, with no exceptions and no user override that weakens it.

### What Apple officially documents (use these; do not invent others)
- Apple's support article "Keep your Mac laptop within acceptable operating temperatures" (https://support.apple.com/102336) and the MacBook Air / MacBook Pro tech specs pages give:
  - Operating ambient temperature: 10° to 35°C (50° to 95°F)
  - Storage temperature: –25° to 45°C (–13° to 113°F)
  - Relative humidity: 0% to 95%, non-condensing
  - Use on a stable surface with good ventilation; not in bed, on a pillow, or under bedding. Treat "lid closed, possibly in a bag" as the same kind of restricted-ventilation situation.
- Apple does NOT publish internal CPU/SoC temperature limits for any MacBook model and does not provide a supported API for raw sensor readings. Do not hardcode internal temperature thresholds, and never present community figures as Apple specifications.

### Primary signal: macOS thermal pressure
- Use `ProcessInfo.thermalState` and observe `ProcessInfo.thermalStateDidChangeNotification` as the main trigger. macOS calibrates it per model, so it works for every MacBook Air and Pro, Intel and Apple silicon.
- Rules while a hold is active:
  - `.critical` → immediate forced release. If the lid is closed and no external display is connected, put the Mac to sleep even if other processes hold sleep assertions.
  - `.serious` → immediate forced release (sleep only if the "never sleep a Mac someone is using" conditions below are met).
  - `.fair` sustained while the lid is closed → forced release after a timeout: 10 minutes by default on Macs with fans, 5 minutes on fanless models (Apple silicon MacBook Airs cool passively). Detect fanless models via the hardware model identifier and keep that list of identifiers in one well-documented place.
  - `.nominal` → no action.
- Never start a new hold, or resume one after the grace period, while the state is `.serious` or `.critical`.
- These timeouts are design choices, not Apple numbers. Document them as such in the README.

### Secondary signals (optional, informational, never the only safeguard)
- Raw temperature readings via private SMC/IOKit interfaces may be shown in the menu for information only, clearly labeled as unofficial and model-dependent. If they're unavailable or fail, nothing else may break. They may only make Hibermate stricter, never looser.

### Battery and power
- On battery power: release at or below the configured threshold (default 20%).
- If macOS Low Power Mode is enabled, hold at most 30 minutes or the configured maximum, whichever is shorter.
- If the battery reports a service-recommended condition (when available through public APIs), show a warning in the menu.

### Time limits
- Maximum hold duration: default 3 hours, hard ceiling 8 hours, regardless of settings.

### Settings can only make things safer
- Users may tighten any safety threshold (lower max hold, higher battery threshold, shorter `.fair` timeout) but can never loosen them past the defaults above. The UI must not offer any way to disable thermal protection.

### Notifications and logging
- Every safety-triggered release posts a local notification explaining the reason (e.g. "Hibermate put your Mac to sleep: it was getting too hot with the lid closed.") and is logged locally with the thermal state, battery level, lid state, and hold duration.

## Other non-negotiable safety invariants
Each one needs a test.

1. **Sleep prevention must never get stuck on.** If the app crashes, is force-quit, is uninstalled, misses a hook event, or the agent is killed with `kill -9`, the system must return to normal sleep behavior within a bounded time (default 2 minutes).
2. **Never clobber the user's existing power settings.** On first run, read and save the current `SleepDisabled` state (`pmset -g`) and any other setting Hibermate touches. If `SleepDisabled` was already 1 before installation, never reset it to 0. Restore original values on uninstall.
3. **Never sleep a Mac someone is using.** Except for the `.critical` thermal rule above, only call sleep when ALL of these are true: the lid is closed (read `AppleClamshellState` through IOKit, not by parsing `ioreg` output), no external display is connected (clamshell mode with an external monitor means the Mac is being used as a desktop), no other process holds a system-sleep-prevention assertion (check `IOPMCopyAssertionsByProcess`, ignoring our own; for example, a download, a Time Machine backup, or the user's own `caffeinate`), and the grace period has passed (forced releases skip the grace period).
4. **Hooks must never interfere with Claude Code.** Every hook script must exit 0 every time, finish in under 100 ms, write nothing to stdout or stderr (output from some hooks, like UserPromptSubmit, is injected into Claude's context, and some exit codes block Claude), never read prompts or transcripts, and still work silently if Hibermate isn't running or has been uninstalled.
5. **No network access and no telemetry.** Logging uses `os_log` locally only. Never read or store transcripts or code, only session IDs, PIDs, timestamps, and event names.
6. **Fail safe.** When anything is uncertain (helper unreachable or not yet approved, state unreadable, sensors unavailable, app running from the wrong location), the default is "no hold, normal macOS sleep behavior."

## Architecture
- **Menu bar app:** SwiftUI `MenuBarExtra`, macOS 14+, universal binary (Apple Silicon and Intel). Runs only as a menu bar icon at the top of the screen: set `LSUIElement = YES` in Info.plist so there is no Dock icon and no app switcher entry. All features are reached from the menu bar icon; Settings opens as a standard window from the menu. Distributed outside the App Store, not sandboxed.
- **Why `caffeinate` alone isn't enough:** standard sleep assertions don't prevent lid-close sleep on battery without an external display. Blocking it requires `pmset -a disablesleep 1`, which needs root.
- **Privileged helper:** registered with `SMAppService.daemon`, with its launchd plist embedded in the app bundle. It exposes a minimal XPC interface with only `setSleepDisabled(Bool)` and `sleepNow()`. It must verify the calling process's code signature and reject anything that isn't Hibermate. It must never run arbitrary commands or accept arbitrary arguments.
- **Dead-man switch inside the helper:** while a hold is active, the app sends a heartbeat to the helper every 30 seconds. If the helper misses heartbeats for 2 minutes, it restores `SleepDisabled` to the user's original value by itself. This enforces invariant 1 when the app crashes.
- **Reconciliation:** on helper start, app launch, and wake from sleep, compare the actual `SleepDisabled` state with the expected state and fix any mismatch toward normal behavior.
- **Fallback (document only; do not implement unless I ask):** a sudoers rule limited to exactly `/usr/bin/pmset -a disablesleep 0` and `/usr/bin/pmset -a disablesleep 1`. If ever used, the file must go in `/etc/sudoers.d/` with mode 0440 and be validated with `visudo -c -f` before being moved into place, because a malformed sudoers file can break `sudo` system-wide.

## Detecting agent activity
### Claude Code (primary, via hooks)
- Install small hook scripts into `~/Library/Application Support/Hibermate/hooks/`.
- Register them in `~/.claude/settings.json` by **merging**, never overwriting: back up the file first, preserve all existing hooks (mine and other tools'), tag our entries so they can be removed precisely, validate the JSON before writing, and write atomically (temp file + rename). If the existing file is corrupt, refuse to edit it and show an error.
- Each hook atomically writes or updates `~/Library/Application Support/Hibermate/sessions/<session_id>.json` with the event name, timestamp, and the PID of the parent Claude Code process.
- Event mapping (adjust to the real hook names confirmed in the docs):
  - Prompt submitted → WORKING
  - Tool use events → heartbeat (refresh the timestamp)
  - Stop → IDLE
  - Session end → remove the session
  - Notification for a permission request or waiting for input → WAITING. With the lid closed nobody can answer, so release the hold after a configurable timeout (default 5 minutes).
  - Subagent stop → heartbeat only, not idle
- **Stale session cleanup:** a session is dead if its PID no longer exists, or if it reports WORKING with no heartbeat for longer than a configurable window (default 15 minutes). Dead sessions are removed and stop holding.

### Other agents (secondary, process watching; off by default)
- Optionally watch processes by name (e.g. `codex`, `aider`, `gemini`), selectable in Settings. Treat "running and using CPU above a small threshold" as working.

### Combining sessions
- The hold is active if ANY session is WORKING. Reference-count by session ID so one session finishing never releases the hold while another is still working.

## State machine
States: `Idle` → `Holding` → `GracePeriod` → `Idle`, plus `ForcedRelease`.
- `Idle → Holding`: the first session becomes WORKING, the helper is approved and reachable, and the thermal state is `.nominal` or `.fair`. Ask the helper to disable sleep and create an `IOPMAssertion` (PreventUserIdleSystemSleep) so idle sleep is blocked even with the lid open. Do NOT prevent display sleep.
- `Holding → GracePeriod`: the last working session goes idle. Start a grace timer (configurable, default 60 s) in case work resumes.
- `GracePeriod → Idle`: the timer expires. Restore the original sleep setting, release the assertion, then check invariant 3. If every condition passes, call `sleepNow()`. If the lid is open, do nothing else; the user's workflow must be unaffected.
- `GracePeriod → Holding`: a session becomes WORKING again and the thermal state allows it. Cancel the timer.
- Any state → `ForcedRelease`: any hardware safety rule triggers (thermal, battery, Low Power Mode limit, max hold). Same cleanup as `GracePeriod → Idle`, skipping the grace period, applying the `.critical` sleep override when relevant, plus a notification.
- All transitions must be idempotent and safe to repeat.

## Menu bar UI
- Icon states: idle, holding (safe to close the lid), grace period, forced release or warning, setup needed (helper not approved or app not in Applications).
- The menu shows which sessions are holding and why (project folder name and elapsed time), the battery level, the thermal state in plain words (e.g. "Cool," "Warm," "Hot"), the time left before the max-hold cutoff, and optionally unofficial sensor temperatures, clearly labeled.
- Actions: "Release now," "Pause Hibermate for 1 hour," "Settings…," "Uninstall Hibermate…," "Quit." Quitting must release everything cleanly.
- Settings window: grace period, max hold duration, battery threshold, `.fair` timeout, permission-wait timeout, stale-session window, process watching on or off, launch at login (via `SMAppService.mainApp`, off by default), notifications on or off. Safety-related settings can only be tightened beyond the defaults, never loosened.
- First-run onboarding explains exactly what will change on the system (helper install, hook entries) and the hardware safety behavior, and asks for consent for each part separately.

## Distribution: DMG on GitHub Releases
The app ships as a `.dmg` downloaded from the repo's GitHub Releases page, like Vorssaint. The user opens the DMG, drags Hibermate into Applications, and launches it; from then on it lives in the menu bar.

### The DMG
- Name: `Hibermate-<version>.dmg` (e.g. `Hibermate-1.0.0.dmg`).
- Contents: `Hibermate.app` and a symlink to `/Applications`, laid out so the drag-and-drop is obvious. A simple background image with an arrow is a nice touch but optional.
- Build it with a script in the repo (`scripts/build-dmg.sh`) using built-in tools (`xcodebuild archive`, `xcodebuild -exportArchive`, `hdiutil`). Avoid extra dependencies unless clearly worth it; if you suggest one (e.g. `create-dmg`), ask me first.
- Publish a SHA-256 checksum next to each DMG in the release notes.

### Running from the right place
- The privileged helper must only be registered when the app runs from `/Applications`. If the app is launched from the DMG, Downloads, or anywhere else (including macOS App Translocation), show a friendly message asking the user to move it to Applications, and offer to quit. Never register the helper from a temporary location.
- After first launch, `SMAppService` may require the user to approve the helper in System Settings → General → Login Items. Detect the "requires approval" state, explain it in plain words in the onboarding, and offer a button that opens that settings pane. Until it's approved, Hibermate must not hold anything (fail safe).

### Signing and Gatekeeper (decide with me before building releases)
- With an Apple Developer ID and notarization, users can open the app normally. This requires the paid Apple Developer Program. Set up the build script so signing and notarization (`notarytool` + `stapler`) can be switched on with environment variables, and never commit credentials.
- Without it, macOS blocks the first launch and the privileged helper may not register reliably for other users. If we ship unsigned builds, the README must explain clearly how to allow the app (System Settings → Privacy & Security → Open Anyway) and the limitations. Verify on a clean macOS user account how the helper behaves with ad-hoc signing, and report the results to me before the first public release.
- Local development uses local-development signing.

### Releases
- Semantic versioning (`1.0.0`), with `CFBundleShortVersionString` and `CFBundleVersion` set from one place.
- Update `CHANGELOG.md` for every release.
- Add a GitHub Actions workflow that builds the DMG on a macOS runner when a version tag (`v*`) is pushed and attaches it to a **draft** GitHub Release, so I can review it before publishing. Signing secrets go in GitHub Actions secrets only.
- Auto-updates (e.g. Sparkle) and a Homebrew cask (`hibermate`) are later goals; list them in the README roadmap but don't build them now.

## Uninstall
An in-app "Uninstall Hibermate…" action and a standalone `uninstall.sh` that works even if the app is broken. Both must restore original power settings, unregister the helper, remove only Hibermate's entries from `~/.claude/settings.json` (keeping a backup), and delete `~/Library/Application Support/Hibermate/`. The in-app action ends by telling the user to drag Hibermate from Applications to the Trash (or does it for them after confirmation). After uninstalling, the system should be in the same state as before installation.

## Testing
- Put all power, IOKit, battery, thermal, model-detection, helper, and process access behind protocols so everything can be unit-tested with fakes. Unit tests must never call real `pmset` or sleep the machine.
- Add a `--dry-run` mode that logs every power action instead of performing it.
- Unit tests must cover:
  - **Hardware safety:** `.critical` forcing sleep even with other sleep assertions when the lid is closed; `.serious` forcing release; sustained `.fair` timeouts on fan vs. fanless models; refusing to start or resume a hold under `.serious`/`.critical`; battery crossing the threshold; Low Power Mode limit; max hold and the 8-hour hard ceiling; settings that try to loosen limits being rejected; SMC readings unavailable.
  - **Other invariants:** overlapping sessions; a lost Stop event; an agent killed with `kill -9`; the app crashing during a hold (dead-man switch); a user who already had `SleepDisabled = 1`; lid open at release (no sleep); external display connected (no sleep); another process holding a sleep assertion (no sleep, except `.critical`); a permission-wait timeout; malformed or missing session files; a corrupt `settings.json` (refuse to edit); the helper unreachable or not yet approved (fail safe, meaning no hold); the app running outside `/Applications` (no helper registration).
- Manual test checklist for real hardware:
  - Install from the DMG on a clean macOS user account; launch directly from the DMG (should ask to move to Applications); approve the helper in Login Items.
  - Lid closed on battery, on AC, and with an external display, during a real Claude Code run.
  - Force-quit the app mid-hold; reboot mid-hold.
  - A sustained heavy workload with the lid closed, to observe thermal releases.
  - Full uninstall, then confirm `pmset -g` and `~/.claude/settings.json` are back to their original state.

## Deliverables
1. The Xcode project (app + helper target), universal binary, menu bar only (`LSUIElement`), with local-development signing.
2. Hook scripts and the settings merge/unmerge logic.
3. `uninstall.sh`.
4. `scripts/build-dmg.sh` producing `Hibermate-<version>.dmg` with the drag-to-Applications layout, plus a SHA-256 checksum.
5. A GitHub Actions release workflow that builds the DMG on version tags and attaches it to a draft release.
6. README, LICENSE (after I choose), `.gitignore`, and `CHANGELOG.md`.
7. Unit tests and the manual test checklist.
8. Kept up to date: `CLAUDE.md` and `docs/SPEC.md`.

Work in small, reviewable steps. After each major component, summarize what changed, what's left, and any decisions you need from me.

---

# Appendix A: Verification notes (added 2026-10-17)

Everything above this line is the original handoff, saved verbatim. The notes below record what was found when the spec was checked against current sources.

## A.1 Apple temperature guidance (checked 2026-10-17)

Sources read: support.apple.com/102336, apple.com/macbook-air/specs/ (M5), apple.com/macbook-pro/specs/ (M5 / M5 Pro / M5 Max), support.apple.com/102869.

| Item | Spec above | support.apple.com/102336 | Current Air/Pro tech specs |
|---|---|---|---|
| Operating ambient | 10–35 °C (50–95 °F) | 10–35 °C (matches) | 10–35 °C (matches) |
| Storage | –25–45 °C (–13–113 °F) | not listed | –25–45 °C (matches) |
| Relative humidity | 0–95 % non-condensing | 0–95 % (matches) | **0–90 % non-condensing (differs)** |
| Altitude | not in spec | not listed | operating tested to 10,000 ft (3,000 m); storage 15,000 ft; shipping 35,000 ft |

- **Difference:** Apple's own pages disagree on humidity. The support article says 95%, but the current tech specs pages say 90%. Hibermate's user-facing docs will quote the stricter tech-specs figure (0–90%) and cite both sources. Hibermate does not use humidity in any logic.
- Ventilation guidance in 102336 matches the spec: a stable surface with good ventilation, not in a bed, on a pillow, or under bedding. The article adds: don't put anything over the keyboard or into vents. It says nothing about lid-closed use or bags, so treating those as restricted ventilation is Hibermate's own conservative reading, not Apple guidance.
- Confirmed: Apple publishes no internal CPU/SoC temperature limits and no public raw-sensor API. The only public signal is `ProcessInfo.thermalState` (nominal, fair, serious, critical).

## A.2 Fanless model identifiers (support.apple.com/102869)

All Apple silicon MacBook Airs are fanless: MacBookAir10,1 (M1), Mac14,2 (M2 13"), Mac14,15 (M2 15"), Mac15,12 / Mac15,13 (M3), Mac16,12 / Mac16,13 (M4), **Mac17,3 / Mac17,4 (M5, newer than the spec's list)**. No Apple silicon MacBook Pro is fanless; even the base 14-inch M5 has a fan (support.apple.com/123156). Intel MacBook Airs have fans.

Design consequence: an identifier missing from the list (a future model) is treated as **fanless** when its name starts with `MacBookAir` or it is otherwise unrecognized. The shorter `.fair` timeout is the safer default.

## A.3 Claude Code hooks (checked 2026-10-17)

Sources read: https://code.claude.com/docs/en/hooks (docs.claude.com now redirects there) and https://code.claude.com/docs/en/settings-reference.

**Event names that matter to Hibermate** (exact spelling): `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PostToolBatch`, `PermissionRequest`, `Notification`, `SubagentStart`, `SubagentStop`, `Stop`, `StopFailure`, `PreCompact`, `PostCompact`, `SessionEnd`. The docs list many more; these are the relevant ones.

**Common stdin fields:** `session_id`, `prompt_id`, `transcript_path`, `cwd`, `permission_mode`, `hook_event_name`, plus optional `agent_id`/`agent_type`, `effort`, and `scratchpad_dir`.

**Differences from, or additions to, the spec:**
1. **`UserPromptSubmit` stdin contains the full prompt text** (`prompt`), and `Stop` contains `last_assistant_message`. Hooks cannot avoid *receiving* this. Hibermate's hook reads stdin into memory, extracts only `session_id`, `hook_event_name`, `notification_type`, `cwd`, and the *count* of `background_tasks`, then discards everything else. It never opens `transcript_path`.
2. **Stdout on exit 0 is injected into Claude's context** for `UserPromptSubmit`, `SessionStart`, `UserPromptExpansion`, and `PostModelSwitch`. Exit 2 blocks `UserPromptSubmit`/`PreToolUse` and prevents `Stop`. Other non-zero codes produce a visible "hook error" line. This confirms invariant 4: always exit 0 with no output.
3. **`Notification` has a `notification_type` field.** Relevant values: `permission_prompt`, `idle_prompt`, `elicitation_dialog`, `agent_needs_input`. There is also a dedicated **`PermissionRequest`** event that fires earlier than the notification.
4. **`StopFailure`** exists. A turn can end on an API error (rate limit, overload, auth) without a normal `Stop`, so it must also map to IDLE.
5. **`Stop` includes `background_tasks`.** Claude may have finished its turn while background tasks keep running and later re-wake it. `UserPromptSubmit` also fires on turns Claude starts by itself.
6. **The parent PID is not documented.** Without `args`, hooks run via `sh -c` on macOS, so `$PPID` may be the shell or Claude. The hook must walk up the process tree to find the Claude Code process.
7. **There is no `id` or `description` field on hook handlers**, and how unknown keys are handled is undocumented. Hibermate therefore identifies its entries by their unique command path (`…/Application Support/Hibermate/hooks/hibermate-hook`) instead of adding custom keys.
8. **Timeouts:** the default is 600 s (30 s for `UserPromptSubmit`). `SessionEnd` hooks share a 1.5 s budget. Handlers accept `timeout`, `async`, `if`, `statusMessage`, `once`, and `shell`/`args`. A matcher of `""` or `"*"` matches everything.
9. **Attribution setting:** `"attribution": {"commit": "", "pr": ""}` hides the trailer and PR line. `includeCoAuthoredBy` is deprecated (since v2.0.62). `"attribution": false` needs v2.1.281+, and older versions skip the whole file, so empty strings are the safer form.
