# Manual test checklist (real hardware)

## Results log
- **2026-10-17, Mac15,6 (14-inch M3 Pro), dev account, ad-hoc build 0.1.0:**
  - The helper registered via SMAppService and was approved in Login Items.
  - Hook → hold within ~1 s → `SleepDisabled 1`.
  - Stop → 60 s grace → restored to the original (0).
  - `kill -9` app mid-hold → helper restored in 1 s (XPC invalidation).
  - Bug found: the helper's re-read after `pmset` lagged, so the first restore was logged as failed and fixed by the 10 s retry. The read now waits up to 1 s.
  - Helper re-registration after an update: the ad-hoc helper is pinned to its cdhash (LWCR), so the updated helper failed with EX_CONFIG. Fixed with automatic re-registration, which needs Login Items approval again.
  - **Lid closed on battery, `scripts/lid-test.sh`:**
    - Control (`--no-hold`): Clamshell Sleep 18:24:07 → wake 18:29:07, a 5-minute gap in the samples.
    - With Hibermate (`--hold`): no gap during the 3-minute run with the lid closed. Released after 60 s of grace, then `sleepNow` → macOS "Software Sleep pid=<helper>" 5 s later. PASS.
    - Found and fixed along the way: powerd's "Prevent sleep while display is on" was counted as a blocking assertion; macOS doesn't sleep by itself after a restore with the lid closed (→ SPEC A.6).
  - **Real Claude Code session with the integration (VS Code extension), lid closed:** the hook started the hold at 19:01:11 (✅), but the **helper's dead-man switch released it at 19:03:11**. With the lid closed, App Nap throttled the app's timers, so heartbeats stopped. The Mac stayed awake only because macOS doesn't re-check lid sleep after a restore. Fixed by opting out of App Nap (`beginActivity(.userInitiatedAllowingIdleSystemSleep)`); needs a re-test.
  - **Re-test after the App Nap fix (2026-10-18), real Claude Code session, lid closed, battery:** hold 09:10:09 → no early release, samples every ~10 s with no gap → grace expired 09:14:27 → `sleepNow` → macOS Software Sleep (helper pid) 09:14:32 → woke on lid open 09:15:26. **PASS.**
  - **Round 1, automated with stand-in agents and the real hook (2026-10-18):**
    - Hooks with Hibermate's files absent: exit 0, no output, 12 ms, no files created. PASS.
    - `kill -9` agent: "dead: processExited" within one 3 s tick, session file removed. PASS.
    - Unanswered permission prompt: waiting → "permissionWaitExpired" after exactly 5 min. PASS.
    - Lost Stop (agent alive, silent): "dead: staleWorking" after exactly 15 min, then released after grace. PASS.
    - A session with background tasks stopped holding after the 15 min stale window ("backgroundStale"). PASS.
  - **Round 2 (2026-10-20), lid closed, `scripts/lid-test.sh run --hold`:**
    - 2a On AC: no gap; slept via the helper after grace ("Using AC"). PASS.
    - 2b On AC with `caffeinate -s`: no gap; after grace, deliberately **not** slept, with the log naming `caffeinate: PreventSystemSleep`. PASS (option A, SPEC A.6).
    - 2c On battery with `caffeinate -i`: no gap; slept via the helper after grace despite the idle assertion. PASS (option A).
    - 2d App crash with the lid closed (`CRASH_APP_AFTER=60`): kill -9 at 00:42:48 → the helper restored `SleepDisabled 0` and requested sleep in the same second → macOS slept 00:42:53 (helper pid). PASS (SPEC A.7).
    - 2e Queued prompts (3 prompts queued in one Claude Code session): the session stayed "holding" continuously (working ↔ background) until all were done, then went idle. PASS at the session level. The Mac-level hold wasn't exercised because the battery was at 19%.
    - Bonus, battery threshold: at 19% on battery (limit 20%), Hibermate correctly **refused to start** a hold. Found a UX gap: the menu said "No agents working". Fixed: it now says why it isn't keeping the Mac awake (`StartBlocker`).
    - Note: Hibermate was quit normally (⌘Q) at 01:05 and, with launch at login off, didn't come back. Not a crash.
  - **Round 3:**
    - 3a User's own `SleepDisabled = 1` (set with `sudo pmset -a disablesleep 1` between holds): the next hold recorded 1 as the original (no "set to 1" write); after release (20:12:31), `SleepDisabled` was **still 1**, with no helper write. PASS (invariant 2).
    - 3c Max hold set to 15 min, 17-min generic job, lid open: "maxHoldReached" at 15:03 after hold start; safety log has thermal, battery, lid, and slept=false; restored; with the lid open the latch cleared and a new hold started 3 s later. PASS.
    - 3b Low Power Mode on, 32-min generic job, lid open: "lowPowerModeLimit" at 30:03 after hold start; safety log complete; latch cleared with the lid open; final release after grace. PASS.
    - 3d Heat test: 15 min of all-core CPU load (one perl busy loop per core), lid closed, on AC, while holding. Thermal pressure stayed **nominal** the whole time (no Hibermate thermal-change log, no thermalmonitord pressure change); no gap in the samples. The thermal releases couldn't be triggered on this Mac (M3 Pro with fans) and are covered by unit tests. Opening the lid during grace correctly cancelled the sleep.
  - Note: the already-running VS Code Claude Code session picked up the new hooks immediately, without a restart.
  - Not yet tested: clean user account, AC with an external display, thermal, reboot mid-hold.

Unit tests cover the logic with fakes. This checklist covers what only a real Mac can show. Record the date, macOS version, and Mac model (`sysctl -n hw.model`) for every run.

Before and after each section, record:

```sh
pmset -g | grep -i sleepdisabled          # expect nothing or 0 when idle
pmset -g assertions | grep -i hibermate   # expect nothing when idle
log show --last 30m --predicate 'subsystem BEGINSWITH "com.sr7d3v.hibermate"' --style compact
```

## 1. Install
- [ ] On a **clean macOS user account**, download the DMG and check its SHA-256.
- [ ] Launch directly from the mounted DMG. Hibermate asks to be moved to Applications and doesn't register the helper.
- [ ] Copy it to /Applications and launch. The unsigned first-launch block is lifted via Privacy & Security → Open Anyway.
- [ ] Install the helper. The "requires approval" state is detected, and the button opens Login Items.
- [ ] Approve the helper. The menu shows "No agents working".
- [ ] **Ad-hoc signing check:** does `SMAppService.daemon` register and run the helper on the clean account? Record the result before the first public release.

## 2. Each integration (enable, run a real session, disable)
For each tool: enable it in onboarding, run one real prompt, check that the menu shows the session as working, that it goes to idle after the turn, and that disabling it restores the config file byte for byte (`diff` against the backup).
- [ ] Claude Code. Also record which process the hook's PID walk lands on (`agent_pid` in `~/Library/Application Support/Hibermate/sessions/claude-code/*.json`).
- [ ] Codex CLI. Trust the hooks in `/hooks`. Check that Stop with empty output causes no warning.
- [ ] Gemini CLI (and Antigravity `agy`, if installed: which config does it read?).
- [ ] Qwen Code (confirm the `~/.qwen/settings.json` path).
- [ ] Copilot CLI. Also check that sessions from Claude hooks run by Copilot are filed as Copilot.
- [ ] Cursor IDE agent and the `agent` CLI. Check that no prompt is ever blocked, and which events the CLI actually fires.
- [ ] OpenCode. The plugin loads with no errors in OpenCode's log.
- [ ] Activity watching: Ollama (GGUF and MLX models), llama.cpp, LM Studio (record real process names), MLX. A loaded but idle model must **not** hold; generating must hold.

## 3. Lid closed during a real agent run
Fastest visible check, with no tool settings changed: `scripts/lid-test.sh run --no-hold`, then `scripts/lid-test.sh run --hold`, running `scripts/lid-test.sh report` after each. The Mac writes a timestamp every 5 s, so gaps show exactly when it slept.

- [ ] On **battery**: start a long task and close the lid. The work continues (check timestamps afterwards), and the Mac sleeps after the work plus the grace period.
- [ ] On **AC**: the same.
- [ ] With an **external display** (clamshell): the Mac stays awake as a desktop; Hibermate never forces sleep.
- [ ] **Queued prompts**: queue 3 prompts, close the lid, and confirm all 3 complete before sleep. Measure the Stop → next UserPromptSubmit gap in the session file timestamps; it must stay under the 30 s grace floor.
- [ ] **Permission prompt** with the lid closed: released after the permission-wait timeout.
- [ ] `caffeinate -i` running (idle-sleep assertion): the Mac **still sleeps** at release, as macOS would on lid close.
- [ ] On AC with `caffeinate -s` running: **no** forced sleep at release, and the log line "Not sleeping the Mac (…)" names caffeinate.
- [ ] Note any system daemon holding a long-lived idle-sleep assertion that blocks Hibermate's sleep call.

## 4. Failure and recovery
- [ ] Force-quit Hibermate mid-hold (Activity Monitor). `SleepDisabled` returns to the original value within 2 minutes (immediately if the XPC connection drop is seen).
- [ ] `kill -9` the agent mid-hold. The session is removed and the hold releases after grace.
- [ ] Reboot mid-hold. After the reboot, `SleepDisabled` is back to the original value before anyone logs in.
- [ ] Set `sudo pmset -a disablesleep 1` yourself before a hold. After the hold it is **still 1**.
- [ ] Delete Hibermate.app while hooks are installed. Agents keep working, with no errors or output from the hooks.

## 5. Thermal and battery
- [ ] A sustained heavy workload with the lid closed (e.g. a long local-model generation). Observe the `.fair` timeout or serious/critical releases, the notification text, and the log entry (thermal state, battery, lid, duration).
- [ ] Battery dropping through the threshold releases the hold. It doesn't re-arm until the lid is opened and the battery is at threshold + 5% or on AC.
- [ ] Low Power Mode: the hold ends at 30 minutes.

## 6. Uninstall
- [ ] In-app Uninstall: every enabled tool's config matches its pre-install backup, the helper is gone (`launchctl print system/com.sr7d3v.hibermate.helper` fails), and both `~/Library/Application Support/Hibermate` and `/Library/Application Support/Hibermate` are gone. `pmset -g` matches the pre-install values.
- [ ] `sh uninstall.sh` on a machine with the app already deleted: the same end state.
