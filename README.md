# Hibermate

**Close the lid. Your agents keep working.**

Hibermate is a free, open-source macOS menu bar app. It keeps your MacBook awake with the lid closed **only while an AI agent or local model is working**: Claude Code, Codex, Gemini CLI, Cursor, Ollama, and more. When the work is done, it lets the Mac sleep. When nothing is working, your Mac behaves exactly as if Hibermate weren't installed.

> **Status: work in progress.** There is no release yet, and it hasn't been tested on real hardware. Please don't install it on a machine you depend on yet.

## Why

A Mac can't run anything while it's asleep, and closing the lid puts it to sleep. So long agent sessions force you to leave the lid open. Hibermate keeps the Mac awake with the display off while work is in progress, then lets it sleep as if you'd just closed the lid.

It is careful about hardware above all. Protecting your Mac always wins over finishing an agent's work.

## Supported tools

Every integration is opt-in, and you choose each one during setup.

| How it's detected | Tools |
|---|---|
| **Hooks** (precise: knows when work starts and stops) | Claude Code, OpenAI Codex CLI, Gemini CLI, Qwen Code, GitHub Copilot CLI, Cursor (editor agent and CLI), OpenCode |
| **Activity watching** (CPU and GPU use; off by default) | Ollama, llama.cpp, MLX, vLLM, LM Studio, LocalAI, Aider, Crush, Amp, Goose, Factory Droid, Kiro CLI |
| **Generic command** (for scripts or anything else) | `hibermate-hook generic start <id>` … `hibermate-hook generic end <id>` |

A loaded but idle local model doesn't keep the Mac awake. Only a model that's actually generating does. Details and caveats are in [docs/AGENTS.md](docs/AGENTS.md).

## Install

1. Download `Hibermate-<version>.dmg` from [Releases](https://github.com/SR7D3V/hibermate/releases) and check its SHA-256 against the one in the release notes: `shasum -a 256 Hibermate-<version>.dmg`.
2. Open the DMG and drag **Hibermate** into **Applications**.
3. Open Hibermate from Applications. Releases are currently **not signed by Apple**, so the first time macOS shows **"Hibermate" Not Opened**. That's expected:
   1. Click **Done** (not *Move to Trash*).
   2. Open **System Settings → Privacy & Security** and scroll down to the **Security** section.
   3. Next to *"Hibermate" was blocked to protect your Mac*, click **Open Anyway**, and confirm with your password or Touch ID. The button appears for about an hour after the blocked attempt; if it's missing, try opening Hibermate once more.
   4. Click **Open Anyway** once more in the final dialog. From then on, Hibermate opens like any other app.

   If you prefer Terminal, this does the same after copying the app: `xattr -dr com.apple.quarantine /Applications/Hibermate.app`
4. Hibermate appears in the menu bar (no Dock icon). Follow the setup window:
   - **Install the helper**, then turn on Hibermate in **System Settings → General → Login Items & Extensions**. Until you approve it, Hibermate keeps nothing awake.
   - **Choose which AI tools to watch.**

Hibermate refuses to install its helper if it's running from the DMG, Downloads, or anywhere other than `/Applications`.

## How it works

- Agents report "started working" and "finished" through small hooks. Local models are detected by their CPU and GPU activity.
- While anything is working, Hibermate asks its helper to run `pmset -a disablesleep 1`, so closing the lid doesn't sleep the Mac. It also holds a standard "prevent idle sleep" assertion. **The display still sleeps normally.**
- When the last session finishes, Hibermate waits a short grace period (60 s by default) in case more work arrives, such as the next queued prompt. Then it restores your original setting. If the lid is closed and nobody is using the Mac, it puts the Mac to sleep.

## Exactly what it changes on your Mac

| What | Where | When |
|---|---|---|
| `SleepDisabled` power setting | system (via `pmset`) | only during a hold; your original value is restored afterwards, even after a crash |
| Privileged helper (launchd daemon) | inside `Hibermate.app`, registered with macOS | when you approve it |
| Helper state file | `/Library/Application Support/Hibermate/` | only while a hold is active |
| Hook entries (backed up first) | `~/.claude/settings.json`, `~/.codex/hooks.json`, `~/.gemini/settings.json`, `~/.qwen/settings.json`, `~/.cursor/hooks.json` | only for tools you enable |
| Hook files Hibermate owns | `~/.copilot/hooks/hibermate.json`, `~/.config/opencode/plugins/hibermate.js` | only for tools you enable |
| Settings, hook program, session status | `~/Library/Application Support/Hibermate/` | always |

Hibermate makes **no network connections** and has no telemetry. Hooks record only session IDs, process IDs, timestamps, event names, and the project folder name. They never record prompts, code, or transcripts. Logs stay on your Mac (`os_log`).

## Hardware safety

Apple's guidance for Mac laptops ([support.apple.com/102336](https://support.apple.com/102336) and the MacBook tech specs) is: operating ambient temperature 10–35 °C (50–95 °F), storage −25–45 °C, relative humidity 0–90% non-condensing, and use on a stable, well-ventilated surface, not in a bed, on a pillow, or under bedding. Apple does not publish internal chip temperature limits, so Hibermate never invents any.

Hibermate relies on **macOS's own thermal pressure signal**, which macOS calibrates for each model:

- **Critical:** releases immediately. If the lid is closed and no external display is connected, it puts the Mac to sleep, even if other apps are blocking sleep.
- **Serious:** releases immediately.
- **Warm (fair) for a sustained period with the lid closed:** releases after 10 minutes on Macs with fans, or 5 minutes on fanless Macs (MacBook Air).
- It never starts or resumes a hold while the Mac is hot.
- **Battery:** releases at 20% (adjustable upward). **Low Power Mode:** holds at most 30 minutes.
- **Maximum hold:** 4 hours by default, adjustable from 15 minutes to a hard limit of 12 hours.
- **After any safety release**, Hibermate stays off until you open the lid again, the Mac has cooled, and the battery has recovered (or the Mac is plugged in).
- **Crash safety:** if Hibermate crashes, is force-quit, or is deleted, normal sleep returns within 2 minutes. If the lid is closed and no external display is connected, the helper also puts the Mac to sleep, so it never stays awake in a bag. If you had `SleepDisabled` set yourself before installing, Hibermate never resets it.
- **It never sleeps a Mac someone is using:** not with the lid open, and not with an external display connected. On power, it also respects apps that block lid-close sleep the way macOS does (for example `caffeinate -s`). Otherwise it puts the Mac to sleep exactly as closing the lid would have. The only exception is critical heat.

All of these timeouts are **Hibermate's own design choices, not Apple numbers**. You can make them stricter in Settings, never looser, and thermal protection can't be turned off.

## Check that it's fully off

```sh
pmset -g | grep -i sleepdisabled
```

No output, or `SleepDisabled 0`, means normal sleep. When no agent is working, this should always be the case.

## Known limitations

- **Unsigned builds:** macOS asks you to approve the first launch (see Install). The helper accepts calls only from `/Applications/Hibermate.app`, but without an Apple Developer ID it can't cryptographically pin the caller's developer identity.
- **Updating unsigned builds:** macOS pins an unsigned helper to its exact build. After an update that changes the helper, Hibermate re-registers it automatically, and you may need to approve it in Login Items again. A Developer ID–signed release would remove this step.
- **Notifications on unsigned builds:** macOS doesn't ask for permission, so Hibermate's notifications are off at first. Turn them on in **System Settings → Notifications → Hibermate** (the Hibermate window has a button for this). Until then, every safety release is still listed under *Recent safety releases*, and a "While you were away" alert appears when you next open the lid.
- **Turning Hibermate off in Login Items quits the app** (that's macOS behavior). After re-approving it there, open Hibermate again from Applications, or turn on *Launch at login* in Settings.
- **Cloud agents without hooks** (waiting on a remote model) use almost no CPU, so activity watching may miss them. Use a hook integration or the generic command instead.
- Some tool details (payload fields, LM Studio's process names, Gemini CLI vs. Antigravity CLI) are still being verified; see [docs/AGENTS.md](docs/AGENTS.md).
- Codex asks you to trust new hooks in its `/hooks` menu before they run.

## Uninstall

Use **Uninstall Hibermate…** in the menu. It restores your sleep setting, removes Hibermate's hooks from every tool (backing up each file), removes the helper, deletes Hibermate's data, and offers to move the app to the Trash.

If the app is broken or already deleted, run the standalone script from this repository:

```sh
sh uninstall.sh
```

## Roadmap

- Testing on real hardware and an Apple Developer ID–signed, notarized release
- Automatic updates (Sparkle)
- Homebrew cask: `brew install --cask hibermate`
- More integrations (VS Code agent hooks, Cline, Windsurf, Goose hooks, Antigravity CLI)

## Building from source

Requires Xcode 16 or later.

```sh
scripts/test.sh          # unit tests
scripts/build-dmg.sh     # dist/Hibermate-<version>.dmg + .sha256
```

Debug builds run with `--dry-run`, which logs every power action instead of performing it. The version is set in `Config/Version.xcconfig`.

## License

Tool logos come from Simple Icons (CC0) and are trademarks of their owners, used only to identify compatible tools; see [docs/THIRD_PARTY.md](docs/THIRD_PARTY.md).


[GPL-3.0](LICENSE)
