# Changelog

All notable changes to Hibermate are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- If the app crashes or stops responding during a hold with the lid closed, the helper restores the sleep setting and also puts the Mac to sleep (only when no external display is connected).
- Project spec, implementation plan, and contributor notes.
- GPL-3.0 license.
- Works with any AI tool on the Mac: hook integrations for Claude Code, OpenAI Codex CLI, Gemini CLI, Qwen Code, GitHub Copilot CLI, Cursor, and OpenCode; activity watching (CPU and GPU time) for local models such as Ollama, llama.cpp, MLX, vLLM, LM Studio, and LocalAI; and a generic command for scripts.
- App icon (a sleeping bear under the moon) and menu bar icons (bear asleep when idle, one eye open while keeping the Mac awake), generated from code by `scripts/icons/render-icons.swift`.
- In-app uninstall and a standalone `uninstall.sh` that restore every changed file and setting.
- `scripts/build-dmg.sh` (universal DMG with SHA-256) and a GitHub Actions workflow that attaches it to a draft release on version tags.
- README and a manual hardware test checklist.
- Xcode project with the menu bar app, privileged helper, and hook binary; `--dry-run` mode.
- HibermateCore package: hold state machine with thermal, battery, Low Power Mode, and max-hold safety rules; re-arm latch; Claude Code hook event mapping and session liveness; order-preserving settings.json merge and unmerge; privileged helper core with a dead-man switch; unit tests.
