# Hibermate implementation plan

Status: **approved 2026-10-17**, with the decisions in §10.
Inputs: [SPEC.md](SPEC.md), including Appendix A with the verified hooks API and Apple specs.

## 1. Components

| Component | What it is | Privilege |
|---|---|---|
| `Hibermate.app` | SwiftUI `MenuBarExtra`, `LSUIElement=YES`, macOS 14+, universal, not sandboxed | user |
| `HibermateHelper` | launchd daemon registered via `SMAppService.daemon`, plist embedded in `Contents/Library/LaunchDaemons/` | root |
| `hibermate-hook` | tiny compiled Swift CLI that Claude Code hooks call | user |
| `HibermateCore` | local Swift package holding all the logic (state machine, safety policy, sessions, settings merge, helper logic) behind protocols | — |

**Why the hook is a compiled binary instead of a shell script:** the hook has to parse JSON from stdin to get `session_id`. Plain `sh` can't parse JSON reliably without `jq`, which isn't installed by default. `/usr/bin/python3` is slow to start, and on Macs without the Command Line Tools it pops up an install dialog. A small Swift binary starts in about 10–30 ms and parses JSON correctly. The app copies it from its bundle into `~/Library/Application Support/Hibermate/hooks/`. (The spec says "hook scripts"; this is the one deliberate deviation.)

## 2. File layout

```
Hibermate.xcodeproj
Config/Version.xcconfig            # MARKETING_VERSION + CURRENT_PROJECT_VERSION (single source)
Config/Signing.xcconfig            # dev signing; release overrides via env vars
Hibermate/                         # app target
  HibermateApp.swift, AppController.swift (wires real implementations)
  UI/ MenuView, SettingsView, OnboardingView, MoveToApplicationsView
  Assets.xcassets (AppIcon, MenuBarIcon template set), Info.plist, Hibermate.entitlements
HibermateHelper/
  main.swift, HelperXPCListener.swift, com.<user>.hibermate.helper.plist
HibermateHook/
  main.swift                       # thin wrapper around HibermateCore.HookHandler
Packages/HibermateCore/
  Package.swift
  Sources/HibermateCore/
    StateMachine/   HoldStateMachine, HoldState, Events
    Safety/         SafetyPolicy, SafetyLimits (clamping), FanlessModels.swift (THE list)
    Sessions/       SessionRecord, SessionStore, SessionAggregator, StaleSessionReaper
    Hooks/          HookHandler (stdin → session file), HookEventMapping
    ClaudeSettings/ SettingsMerger (merge/unmerge, backup, atomic write)
    Helper/         HelperCore (dead-man switch, original-value persistence, reconciliation)
    System/         protocols: PowerSettings, SleepAssertions, LidSensor, DisplaySensor,
                    BatterySensor, ThermalSensor, ModelInfo, ProcessInspector, HelperClient,
                    Clock, Notifier, AppLocation
  Sources/HibermateSystem/          # real IOKit / ServiceManagement / CoreGraphics implementations
  Sources/HibermateXPC/             # shared @objc XPC protocol
  Tests/HibermateCoreTests/         # all unit tests, fakes only
scripts/build-dmg.sh
uninstall.sh
.github/workflows/release.yml      # v* tag → DMG → draft release
.github/workflows/test.yml         # (proposed) swift test on push/PR
docs/SPEC.md  docs/PLAN.md  docs/MANUAL_TESTS.md
README.md  CHANGELOG.md  LICENSE  .gitignore  CLAUDE.md
```

The logic lives in an SPM package so `swift test` runs fast and never needs the app or root. The `.xcodeproj` is written by hand and kept minimal: four targets plus the package dependency. No XcodeGen or other generator unless you want one.

## 3. Agent detection

### Hook registration (`~/.claude/settings.json`)
For each event, Hibermate adds one matcher group with `"matcher": ""` and this handler:
```json
{ "type": "command", "timeout": 5,
  "command": "f=\"$HOME/Library/Application Support/Hibermate/hooks/hibermate-hook\"; [ -x \"$f\" ] && \"$f\" >/dev/null 2>&1; exit 0" }
```
- The guard means a leftover entry still exits 0 silently after Hibermate is deleted (invariant 4). It never produces a "command not found" error.
- **Tagging:** an entry is ours exactly when its `command` contains `/Application Support/Hibermate/hooks/hibermate-hook`. No custom JSON keys, because the docs don't say whether unknown keys are accepted.
- **Merge:** read the file. If it is unparseable or not an object, **refuse** and show an error. Back up to `settings.json.hibermate-backup-<timestamp>`. Remove our old entries, append the new ones, and keep every other key and hook untouched. Re-serialize, re-parse to validate, write to a temp file in the same directory, `fsync`, then `rename`. Unmerge uses the same steps and removes only our entries. Empty arrays and objects we created are removed so the file returns to its original shape.
- Hooks are synchronous (`async` is not set), so events stay in order. The hook itself takes under 100 ms.

### Event → session state
| Event | Effect |
|---|---|
| `SessionStart` | register the session as IDLE (records Claude's PID and the project folder name) |
| `UserPromptSubmit` | **WORKING** |
| `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PostToolBatch`, `SubagentStart`, `SubagentStop`, `PreCompact`, `PostCompact` | heartbeat. A session in WAITING goes back to WORKING (a tool running means the permission was answered) |
| `PermissionRequest`; `Notification` with `permission_prompt` / `elicitation_dialog` / `agent_needs_input` | **WAITING**. Released after the permission-wait timeout (default 5 min) |
| `Stop` with no background tasks, `StopFailure`, `Notification` `idle_prompt` | **IDLE** |
| `Stop` with `background_tasks` non-empty | **BACKGROUND**: still counts as working, but only for the stale-session window (default 15 min). A background task that re-wakes Claude fires `UserPromptSubmit` |
| `SessionEnd` | delete the session file |

### Session files
`~/Library/Application Support/Hibermate/sessions/<session_id>.json`: `{v, session_id, state, event, ts, claude_pid, project, bg_count}`.
- `session_id` is validated against `[A-Za-z0-9_-]{1,128}`. Anything else is dropped, which prevents path traversal.
- The file is written atomically (temp file + rename). The hook stores no prompt text, transcript path, or code.
- **PID:** the hook walks its ancestor chain with `sysctl(KERN_PROC_PID)` and records the first ancestor that isn't a shell (`sh`/`bash`/`zsh`/`dash`). The plan is to check this empirically against a real Claude Code process before relying on it.
- **Project name:** this stores `basename(cwd)` (for example `hibermate`) for the menu. The spec says to store "only session IDs, PIDs, timestamps, event names" but also wants the project folder name in the menu. **Decision needed (§10).**

### App side
- The app watches the sessions directory with a `DispatchSource` and also polls every 10 s as a fallback.
- **Dead PID:** detected immediately with `DispatchSource.makeProcessSource(.exit)`, and backed up by the poll.
- **Stale session:** WORKING or BACKGROUND with no heartbeat for longer than the stale window → removed.
- Malformed or unreadable files are ignored (and deleted if older than the stale window). They never hold.
- **Aggregation:** the hold is wanted if any live session is WORKING or BACKGROUND, using a set of session IDs as the reference count. WAITING counts only until its timeout.
- **Queued prompts (user requirement):** a user may queue several prompts in one or more CLIs before closing the lid, and all of them must run before the Mac sleeps. Claude Code either feeds a queued message into the current turn, so no `Stop` fires and the hold simply continues, or ends the turn with `Stop` and then submits the next queued prompt, which fires `UserPromptSubmit`. The second case leaves a short gap with no work. Handling:
  - The grace period, which keeps `SleepDisabled=1`, spans that gap. Grace can't be set below 30 s, so a `Stop` → `UserPromptSubmit` handoff never reaches release.
  - Sessions are reference-counted, so a queue in one terminal keeps holding while another terminal finishes.
  - `Stop` with background tasks keeps holding (BACKGROUND, above).
  - Hooks give no way to read the queue directly. The exact `Stop`/`UserPromptSubmit` timing between queued prompts gets measured on a real Claude Code session before release (manual checklist), and the 30 s floor gets raised if it falls short.
  - Tests cover: `Stop` followed by `UserPromptSubmit` within grace → no restore and no helper churn; three queued prompts across two sessions → one continuous hold; the queue drained → grace → sleep.
- **Long tool calls:** `PreToolUse`/`PostToolUse` track the `tool_use_id`s in flight. While a tool is running (for example a 30-minute build), the stale window stretches to 60 min, so a long command isn't mistaken for a lost `Stop`. Max hold still bounds it. Parallel hook invocations are serialized with a short, bounded `flock`.
- **Known limitation (settings merge):** if the user had an empty array for an event Hibermate registers (e.g. `"Stop": []`), uninstall removes that empty array. Both mean "no hooks", and the timestamped backup keeps the original bytes. Everything else round-trips byte for byte.
- **Process watching** (off by default) feeds synthetic sessions into the same aggregator. A watched process counts as working if it exists and its CPU over the last 30 s is above 2%.

## 4. State machine

States: `idle`, `holding(since)`, `grace(until)`, `forcedRelease(reason)`, plus two gates, `setupNeeded` and `paused(until)`, that block entering `holding`.

The machine is a pure value type, `(State, Event, Environment) → (State, [Effect])`. Effects are `helperDisableSleep`, `helperRestore`, `createAssertion`, `releaseAssertion`, `sleepIfSafe(overrideAssertions:)`, `notify`, `log`, and `startTimer`/`cancelTimer`. An effect executor runs them, and in `--dry-run` mode it only logs them. Every effect is idempotent: restoring twice, or releasing an assertion that isn't held, is a no-op.

| From | Trigger | Guard | To / effects |
|---|---|---|---|
| idle | aggregator says "wanted" | helper approved and reachable, app in /Applications, thermal ∈ {nominal, fair}, battery check passes, not paused, not latched | holding: disable sleep via helper, create `PreventUserIdleSystemSleep` assertion, start 30 s heartbeat |
| holding | nothing wanted | — | grace: start the grace timer (default 60 s) |
| grace | wanted again | same guards as idle→holding | holding: cancel the timer |
| grace | timer fires | — | idle: restore, release the assertion, then `sleepIfSafe` (invariant 3) |
| any | safety rule fires | — | forcedRelease → idle: restore, release, `sleepIfSafe` (with the assertion override only for `.critical`), notify, log |
| holding/grace | helper call fails or the connection drops | — | idle (fail safe), restore attempted, warning icon |
| any | user "Release now", Quit, Uninstall | — | idle: restore and release, **no sleep** (the user is at the machine) |

**Re-arm rule after a forced release (approved):** stay latched (no new holds) until the lid has been opened again, *and* thermal is `.nominal`/`.fair`, *and* the battery is above threshold + 5% or on AC. Without this rule, the next prompt from a background task could immediately re-hold a Mac that was just released for heat, or chain max-hold windows indefinitely.

**Display sleep is never prevented.**

## 5. Safety policy (`SafetyPolicy`, evaluated on every sensor change and every 15 s)

- **Thermal:** `.critical` → forced release, plus sleep if the lid is closed and no external display is connected, even when other processes hold assertions. `.serious` → forced release, sleep only if invariant 3 holds. `.fair` sustained for `fairTimeout` while the lid is closed: 10 min with fans, 5 min fanless, measured continuously, with the timer reset whenever the state leaves `.fair` or the lid opens.
- **Fanless detection:** `sysctlbyname("hw.model")` checked against `FanlessModels.swift`: MacBookAir10,1, Mac14,2, Mac14,15, Mac15,12, Mac15,13, Mac16,12, Mac16,13, Mac17,3, Mac17,4, each with its source URL. **An unknown identifier counts as fanless** (the stricter choice). Known fan models are listed explicitly and fall into the 10-minute group.
- **Battery:** read from `IOPSCopyPowerSourcesInfo`. On battery at or below the threshold (default 20%) → forced release. Low Power Mode (`ProcessInfo.isLowPowerModeEnabled` plus its notification) caps the hold at min(30 min, max hold). If `kIOPSBatteryHealthConditionKey` reports a service condition, the menu shows a warning.
- **Max hold (user decision, 2026-10-17, supersedes the spec's 3 h / 8 h):** default **4 h**. Users may set anything from **15 min to 12 h**. **12 h is the hard ceiling**: no setting, corrupted file, or code path can exceed it. Raising the ceiling requires a new release. The limit is measured as total time in `holding`, and time in grace counts too. The thermal, battery, and Low Power Mode rules apply regardless, so a long max hold never weakens them.
- **`SafetyLimits`** clamps every other setting so it can only get stricter: `batteryThreshold ≥ 20%`, `fairTimeout ≤ default(model)`, `permissionWait ≤ 5m`, `staleWindow ≤ 15m`. Grace is the exception: 30 s–5 min, default 60 s. A longer grace only extends a hold that's already bounded by max hold, and the 30 s floor protects queued prompts (§3). Out-of-range values are clamped, and the UI only offers valid ranges. There is no thermal on/off toggle anywhere.
- **SMC temperatures** are optional and informational only. They are read through a protocol, any failure produces `nil`, and they are labeled "unofficial" in the menu. They are not wired into any release decision in v1, so they can't loosen anything.
- Every forced release posts a notification (if enabled) and writes an `os_log` entry with the thermal state, battery level, lid state, and hold duration.

## 6. Sensors (real implementations in `HibermateSystem`)

| Need | API |
|---|---|
| Lid closed | `IORegistryEntryCreateCFProperty(IOPMrootDomain, "AppleClamshellState")` |
| External display | `CGGetOnlineDisplayList` + `CGDisplayIsBuiltin` (any online non-built-in display counts) |
| Other sleep assertions | `IOPMCopyAssertionsByProcess`, filtered to `PreventSystemSleep`/`PreventUserIdleSystemSleep`/`NoIdleSleepAssertion`, excluding our PID and the helper's |
| SleepDisabled read | `IOPMCopySystemPowerSettings()["SleepDisabled"]` |
| SleepDisabled write (helper) | `IOPMSetSystemPowerSetting(kIOPMSleepDisabledKey, …)` if it works from a root daemon. Otherwise `Process` running `/usr/bin/pmset` with a **fixed, literal argv** (`-a disablesleep 0|1`), no shell, no caller-supplied strings |
| Sleep now (helper) | `IOPMSleepSystem(IOPMFindPowerManagement(…))` |
| Model | `sysctlbyname("hw.model")` |
| Wake | `NSWorkspace.didWakeNotification` → reconcile |
| App location | `Bundle.main.bundleURL` must be under `/Applications/`, and `SecTranslocateIsTranslocatedURL` must be false |

**Known risk to test on hardware:** some system daemons keep long-lived idle-sleep assertions. If one does, invariant 3 means Hibermate won't call `sleepNow()`. The Mac then falls back to normal macOS behavior (idle sleep, or clamshell sleep once powerd re-evaluates), which is safe but may sleep later than intended. Logs record which assertion blocked the sleep, and the manual checklist covers this case.

## 7. Privileged helper

- **XPC interface:** `setSleepDisabled(Bool)`, `sleepNow()`, and `heartbeat()` (approved). It takes no other arguments and runs no commands. `heartbeat()` only resets the dead-man timer.
- **Caller check:** `NSXPCConnection.setCodeSigningRequirement(...)` (macOS 13+).
  - **v1 ships unsigned (ad-hoc).** The requirement is `identifier "com.sr7d3v.hibermate"`. The helper also checks that the caller's executable, resolved from its audit token, is exactly `/Applications/Hibermate.app/Contents/MacOS/Hibermate`. This blocks casual spoofing but not a determined local attacker who can write to /Applications. The impact is limited to the two power calls. This is documented in the README.
  - **Upgrade path:** with Developer ID, add `anchor apple generic and certificate leaf[subject.OU] = "<TEAMID>"`. That's a single constant in the helper.
- **Semantics that enforce invariant 2:** `setSleepDisabled(true)` → if no hold is recorded, read the current SleepDisabled and save it as `original` in a root-owned `/Library/Application Support/Hibermate/helper-state.plist`, then set it to 1. `setSleepDisabled(false)` → write back `original` and **never** set 0 unconditionally. If the user already had 1, it stays 1. Then delete the state file, so it exists only while a hold is active.
- **Dead-man switch:** while a hold is active, if 2 min pass without a heartbeat (the app sends one every 30 s), the helper restores. It also restores immediately when the XPC connection is invalidated (the app crashed or was force-quit) and on SIGTERM (unregistration or uninstall). Timers use the monotonic clock.
- **Reconciliation:** on helper start, a leftover state file means a hold was interrupted (crash or reboot), so the helper restores and deletes it. On app launch and wake, the app asks the helper to reconcile: if the app isn't holding, the helper restores.
- The helper never touches the network and logs only through `os_log`. The app's only network request is the daily update check (SPEC A.8).

## 8. Distribution

- **`scripts/build-dmg.sh`:** `xcodebuild archive` (Release, `ARCHS="arm64 x86_64"`), `-exportArchive` (Developer ID method if `HIBERMATE_SIGN_IDENTITY` is set, otherwise ad-hoc), and an optional notarize-and-staple step if `HIBERMATE_NOTARY_PROFILE` (a `notarytool` keychain profile) is set. Then a staging folder (`Hibermate.app` + `Applications` symlink), `hdiutil create -format UDZO`, writes `dist/Hibermate-<ver>.dmg` and `.sha256`, and runs `lipo -archs` to verify the binary is universal. It uses only built-in tools; the background image is skipped in v1.
- **Signing (user decision):** v1 releases are **ad-hoc signed** (`codesign -s -`; Apple silicon requires at least that) and not notarized. The README explains *System Settings → Privacy & Security → Open Anyway*. Local development uses your free Apple ID "Apple Development" (Personal Team) certificate or ad-hoc. The Developer ID and notarytool path stays in the script behind env vars for later. Before the first public release, I'll test helper registration on a clean user account with an ad-hoc build and report the results.
- **Version:** `Config/Version.xcconfig` is the only source, and the script reads it from there.
- **`release.yml`:** on `v*`, a macOS runner checks that the tag matches the xcconfig version, runs `swift test`, runs `build-dmg.sh`, and creates a **draft** release with `gh release create --draft`, the DMG attached, and the checksum in the notes. Signing secrets come only from Actions secrets, and the step is skipped if they're absent.
- **Location gate:** the app registers the helper only from `/Applications` and never when translocated. Otherwise it shows a "Move to Applications" window with a Quit button.
- **Approval:** if `SMAppService.status == .requiresApproval`, onboarding explains this and offers a button that runs `SMAppService.openSystemSettingsLoginItems()`. The app does not hold until the status is `.enabled` **and** a test XPC ping succeeds.

## 9. Testing

**Unit tests** (Swift Testing, in `HibermateCore`, using fakes plus an injectable `FakeClock`; no real `pmset` or sleep):
- **Safety:** critical-forces-sleep-despite-assertions (lid closed); serious-forces-release; fair-timeout for fan (10 m) and fanless (5 m) models; unknown-model-is-fanless; no start or resume under serious/critical; battery threshold crossing; Low Power Mode cap; max hold (default 4 h) and the 12 h hard ceiling; loosening settings rejected or clamped; SMC unavailable.
- **Invariants:** overlapping sessions; a lost Stop (stale reaper); `kill -9` (fake PID exit); app crash (HelperCore dead-man fires with no heartbeat, on connection invalidation, and on SIGTERM); original `SleepDisabled = 1` preserved; lid open (no sleep); external display (no sleep); foreign assertion (no sleep unless critical); permission-wait timeout; malformed or missing session files; corrupt settings.json (refuse); merge preserves foreign hooks and unmerge round-trips byte-equivalently; helper unreachable or unapproved (no hold); outside /Applications or translocated (no registration); reboot mid-hold (reconcile); queued prompts (Stop → UserPromptSubmit within grace keeps one continuous hold; three queued prompts across two sessions); re-arm latch; idempotent effects; bad `session_id` rejected; the hook writes nothing to stdout and stderr and always exits 0 (an integration test runs the built binary with garbage stdin, a missing dir, and a read-only dir, and asserts p95 < 100 ms).

**Manual checklist** (`docs/MANUAL_TESTS.md`): the scenarios from the spec, plus checking the hook PID-walk against a real Claude Code process, measuring the Stop → UserPromptSubmit gap between queued prompts, the long-lived-assertion check, and a clean-account ad-hoc helper registration test.

## 10. Decisions (made by the user, 2026-10-17)

1. **Bundle IDs:** `com.sr7d3v.hibermate` and `com.sr7d3v.hibermate.helper`.
2. **License:** GPL-3.0.
3. **Release signing:** unsigned (ad-hoc) for now; there's no paid Developer ID yet. See §7 and §8.
4. **Attribution:** turned off in the project's `.claude/settings.json` (`attribution.commit` and `attribution.pr` set to `""`).
5. **Project folder name:** allowed. Session files store `basename(cwd)` so the menu can show what's running and where. Invariant 5 is amended accordingly; full paths are not stored.
6. **Re-arm latch after a forced release:** approved with all three conditions (lid reopened, thermal nominal or fair, battery above threshold + 5% or on AC).
7. **Max hold:** user-adjustable from 15 min to 12 h. The default is 4 h, and 12 h is the hard ceiling (raising it needs a new release). This supersedes the spec's 3 h default and 8 h ceiling.
8. **Compiled hook binary and the `heartbeat()` XPC method:** approved. New requirement: prompts queued before the lid closes must all run before sleep (§3).
