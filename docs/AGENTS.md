# Supported AI tools and how Hibermate detects them

Requirement (user, 2026-10-17): Hibermate must work with **any AI agent or LLM in use on the Mac**, not just Claude Code.

Hibermate never makes network requests, not even to localhost. Detection therefore comes from two local sources:

1. **Hooks.** The tool runs `hibermate-hook <agent>` at lifecycle events. This is precise: start, finish, waiting, ended.
2. **Activity watching.** Hibermate looks at running processes plus their CPU and **GPU time**. This is best effort and covers tools without hooks, including local LLM runtimes.
3. **Manual / generic.** `hibermate-hook generic start|heartbeat|wait|stop|end <id>` works for scripts and anything else.

Every integration is opt-in, and onboarding asks for consent to each one separately.

Research date: 2026-10-17. "Unconfirmed" items need a real-world check before release (see the manual checklist).

## 1. Hook integrations

All of them share the hook binary and the same `AgentSignal` mapping. Hibermate's entries are recognized by the `…/Application Support/Hibermate/hooks/hibermate-hook` path in the command.

| Tool | Config Hibermate edits | Format | Working | Idle / finished | Waiting | Ended | Notes |
|---|---|---|---|---|---|---|---|
| **Claude Code** | `~/.claude/settings.json` (merge) | `hooks.<Event>[].hooks[]` | `UserPromptSubmit` | `Stop`, `StopFailure`, `Notification:idle_prompt` | `PermissionRequest`, `Notification:permission_prompt` | `SessionEnd` | Verified (SPEC A.3) |
| **OpenAI Codex CLI** | `~/.codex/hooks.json` (merge) | same shape as Claude | `UserPromptSubmit` | `Stop` | `PermissionRequest` | `SessionEnd`, `Interrupt` | **The user must trust the hooks in Codex's `/hooks`** (hash-based). Plain stdout is injected on `SessionStart`, `UserPromptSubmit`, and `SubagentStart`; output nothing |
| **Gemini CLI** | `~/.gemini/settings.json` (merge) | `hooks.<Event>[].hooks[]`, `timeout` in ms, `name` field | `BeforeAgent` | `AfterAgent` | `Notification:ToolPermission` | `SessionEnd` | Exit 2 on `AfterAgent` forces a retry; non-JSON stdout becomes a system message, so output nothing. Antigravity CLI (`agy`) replaced it for some users; its hook format is **unconfirmed** |
| **Qwen Code** | `~/.qwen/settings.json` (merge) | Claude-compatible | `UserPromptSubmit` | `Stop` | `PermissionRequest`, `Notification` | `SessionEnd` | User settings path **unconfirmed** |
| **GitHub Copilot CLI** | `~/.copilot/hooks/hibermate.json` (own file) | `{"version":1,"hooks":{…:[{"type":"command","bash":…,"timeoutSec":…}]}}` | `userPromptSubmitted` | `agentStop` | `notification:permission_prompt`, `permissionRequest` | `sessionEnd` | Avoid `preToolUse` (it fails closed). Copilot also runs hooks from `.claude/settings.json`; Hibermate relabels those sessions by parent process |
| **Cursor** (IDE + `agent` CLI) | `~/.cursor/hooks.json` (merge) | `{"version":1,"hooks":{"stop":[{"command":…}]}}` | `beforeSubmitPrompt` | `stop` | — | `sessionEnd` | **Never hook permission events** (`preToolUse`, `beforeShellExecution`, …): empty output blocks them. Reply `{}`. The CLI fires only some events |
| **OpenCode** | `~/.config/opencode/plugins/hibermate.js` (own file) | JS plugin forwarding events | `session.status: busy` | `session.idle` | `permission.asked` | process exit | Plugin runs in-process; it must never throw or await |

**Not yet integrated by hook** (watched as processes instead, or planned):
- Aider: only `--notifications-command`, which fires on "idle" only.
- Amp: experimental plugin API.
- Goose: hooks shipped May 2026; plugin layout unconfirmed.
- Factory Droid: Claude-compatible, but file layout unconfirmed.
- Kiro CLI: stdout is injected into context.
- Cline: TaskStart/TaskComplete hook files; output contract unconfirmed.
- Windsurf Cascade hooks.
- VS Code agent hooks (Preview; Claude-compatible; the user-level location still needs verifying).
- Crush: `PreToolUse` only.

## 2. Activity watching (no hooks needed)

The aim is to tell "the model is loaded but idle" apart from "the model is generating" or "the agent is working".

- **Processes:** found with `proc_listallpids`, then name and argv via `sysctl(KERN_PROCARGS2)`. Only the user's own processes are inspected; no root.
- **CPU time:** `proc_pid_rusage` (user + system time), measured as a delta between polls.
- **GPU time (Apple silicon):** each `AGXDeviceUserClient` under `IOAccelerator` in the IORegistry has `IOUserClientCreator` (`"pid N, name"`) and `AppUsage[].accumulatedGPUTime` (ns).
  - This is readable without root, and it's how macmon and mactop do it.
  - It is undocumented and may change, so if it's missing, Hibermate falls back to CPU only.
- **Working rule:** CPU above 5% or GPU above 5% of the poll interval counts as active. The session stays "working" for a 90 s quiet period after its last activity, which bridges gaps between requests. After that it goes idle, then grace, then sleep.
- **Limitation:** a CLI agent that's waiting on a remote model API uses almost no CPU, so process watching may miss it. Hooks are the reliable path for cloud agents; process watching is mainly for **local** inference.

| Watcher | Matches (exact names from source/docs) |
|---|---|
| Ollama | `llama-server` whose parent is `ollama`, or `ollama` with argv[1] `runner` (Ollama ≥ 0.40) |
| llama.cpp | `llama-server`, `llama-cli`, `llama-mtmd-cli` |
| MLX / mlx-lm | Python with argv containing `mlx_lm` |
| vLLM (vllm-metal) | Python with argv containing `vllm` and `serve` |
| LM Studio | `llmster`, `lms`, `LM Studio Helper*` (**unconfirmed**) |
| Jan | `llama-server` under Jan (covered by llama.cpp) |
| LocalAI | `local-ai` and its backend children |
| Aider | Python with argv containing `aider` |
| Other CLI agents | `crush`, `amp`, `goose`, `droid`, `kiro-cli`, `codex`, `gemini`/`qwen` (node argv) |

No local runtime checked creates a sleep assertion while generating (Ollama source, llama.cpp, MLX, Jan, LocalAI). VS Code + Copilot Chat does create one (Electron `prevent-app-suspension`) while streaming. Hibermate already refuses to sleep while any foreign assertion exists, but such an assertion does not *start* a hold.

## 3. Safety is identical for every source

Every integration feeds the same `SessionAggregator` → `HoldEngine`. Thermal, battery, Low Power Mode, max hold, the latch, and the "never sleep a Mac in use" rules apply regardless of which tool asked. A misbehaving integration can at worst keep a hold alive until the stale window, permission timeout, or max hold ends it.
