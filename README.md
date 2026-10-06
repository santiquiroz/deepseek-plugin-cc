# deepseek-plugin-cc

Delegate coding tasks from [Claude Code](https://claude.com/claude-code) to
[DeepSeek Harness](https://www.deepseek.com/)'s CLI (`dsh`) in headless mode.

Claude Code stays the orchestrator — it writes the domain logic, defines each
subtask contract, and reviews the diffs. DeepSeek Harness is **the preferred
first agentic lane**: the delegate reads and edits files and runs commands in
your repo itself, under an OS-level sandbox confined to the working directory,
and `--read-only` refuses edits for reviews and diagnoses that must not touch
the working tree. `deepseek-flash` covers mechanical work and `deepseek-v4-pro`
covers reasoning work; billing is your DeepSeek platform balance (pay-as-you-go).

Sibling of [copilot-plugin-cc](https://github.com/santiquiroz/copilot-plugin-cc),
[antigravity-plugin-cc](https://github.com/santiquiroz/antigravity-plugin-cc),
[ollama-plugin-cc](https://github.com/santiquiroz/ollama-plugin-cc),
[cursor-plugin-cc](https://github.com/santiquiroz/cursor-plugin-cc) and
[bipolar-plugin-cc](https://github.com/santiquiroz/bipolar-plugin-cc), all
inspired by the structure of [openai/codex-plugin-cc](https://github.com/openai/codex-plugin-cc).
**Not affiliated with DeepSeek, OpenAI, GitHub, Google or Anthropic.**

> Lea esto en español: [README.es.md](README.es.md)

## Where it sits in a delegation chain

| Tier | Delegate | Good for |
|---|---|---|
| trivial | [ollama-plugin-cc](https://github.com/santiquiroz/ollama-plugin-cc) | one-shot text transforms on a small local model |
| medium (local) | [bipolar-plugin-cc](https://github.com/santiquiroz/bipolar-plugin-cc) | bounded agentic tasks on a big local model |
| **first lane** | **deepseek-plugin-cc (this)** | mechanical work on `deepseek-flash`, reasoning work on `deepseek-v4-pro`; preferred over the other cloud lanes |
| mechanical (fallback) | [copilot-plugin-cc](https://github.com/santiquiroz/copilot-plugin-cc) | boilerplate, renames, simple specs, cleanup |
| extra agentic lane | [cursor-plugin-cc](https://github.com/santiquiroz/cursor-plugin-cc) | bounded tasks when the other lanes are out of quota, read-only second opinions |
| frontier, second lane | [antigravity-plugin-cc](https://github.com/santiquiroz/antigravity-plugin-cc) | Codex fallback, second opinions |
| frontier, primary | Codex / your main reasoning delegate | architecture-adjacent implementation, deep diagnosis |

Only the lanes you install exist; the plugin works alone too.

## Requirements

- Claude Code. The forwarder runs through the Bash tool (Git Bash on Windows).
- [DeepSeek Harness](https://www.deepseek.com/) desktop app — verified on
  **0.2.0-rc.2** (Windows 11). Signed in once (the account token is read from
  `${DSH_HOME:-$HOME/.dsh}/.credentials.yaml`), or a `DEEPSEEK_API_KEY`
  exported in the environment.

## Install

In Claude Code:

```
/plugin marketplace add santiquiroz/deepseek-plugin-cc
/plugin install deepseek@deepseek-plugin-cc
```

Then, once per machine:

```
/deepseek:setup
```

Setup locates the CLI, checks the version and the provider/sign-in, and tells
you how to fix either when it is missing.

## Usage

```
/deepseek:rescue add unit tests for src/utils/money.ts covering rounding and negative amounts (signatures pasted below) ...
/deepseek:rescue --background rename UserDto to UserResponse across src/api and update the imports
/deepseek:rescue --read-only review src/services/billing.ts for race conditions; report only
/deepseek:rescue --model deepseek-v4-pro diagnose this build failure across the module graph ...
```

### Flags and limits

Put the flags first, then the task text.

- `--wait` (default) — foreground. Claude Code awaits a detached `dsh` job
  through repeated `wait` slices. Interrupting the subagent leaves the job
  running; retain its id to `wait` or `cancel` it later. Edits remain in your
  working tree.
- `--background` — the subagent runs in the background and its output is
  relayed when the run ends. Use it for anything longer than a minute.
- `--model <slug>` — `deepseek-flash` (default, mechanical work) or
  `deepseek-v4-pro` (reasoning work).
- `--read-only` — runs `DSH_PERMISSION_MODE=read-only`: file edits are refused.
  Paste the diff or the code into the task instead of asking the delegate to
  run `git diff`.
- `--continue` — resume the last delegated run in this repo. The subagent adds
  it automatically when your request clearly continues prior delegated work
  ("continue", "keep going", "resume").

Runs last up to `DEEPSEEK_RESCUE_MAX_SECONDS` (default 2700 seconds, 45 minutes).
`start` detaches the job and `wait` awaits it in 480-second slices (maximum
540), each in a separate foreground Bash call with timeout 600000 ms, never
`run_in_background`. The call budget is `1 + 1 + ceil(MAX/480) + 1`.
The old 9-minute cap (`timeout -k 10 540`) left room below the Bash tool's
600-second ceiling; the unchanged `run` command keeps that cap as the short
path. The subagent asks for `--json` and prints only new progress per slice —
assistant text, one line per tool call, a line per denial. A wait past the
deadline kills the process tree with exit 124; `cancel <id>` does so with exit
130. Edits made until then remain in your working tree.

## Proactive delegation

The `deepseek-rescue` agent's description tells Claude Code to use it on its own
as the first lane. That run sends the task text to DeepSeek's backend and lets
the model edit files in the current repository inside a workspace-confined
sandbox. What stands between that and your working tree is Claude Code's own
permission system: the subagent's only tool is `Bash`, so in the default
permission mode you approve the launch command before it runs, while under
bypass mode it runs unprompted. If you want delegation only on request, skip
the CLAUDE.md snippet and add this line to `~/.claude/CLAUDE.md`:

```
Never launch deepseek:deepseek-rescue on your own; use it only when I invoke /deepseek:rescue explicitly.
```

To make proactive delegation routine instead, paste the block from
[docs/claude-md-snippet.md](docs/claude-md-snippet.md) into your `CLAUDE.md`;
lane split, WIP caps and the fallback chain are in
[docs/delegation-guide.md](docs/delegation-guide.md).

## What the forwarder actually runs

The subagent calls `preflight`, `start` and repeated `wait` slices through
`scripts/deepseek-forward.sh`, which holds every deterministic step (tested
with a fake `dsh` in `tests/run.sh`). Each command is a separate Bash call:

```bash
bash scripts/deepseek-forward.sh preflight [--model <slug>]
bash scripts/deepseek-forward.sh start --model <slug> [--read-only] [--continue] <<'DEEPSEEK_TASK_<nonce>'
<your task, verbatim>
DEEPSEEK_TASK_<nonce>
bash scripts/deepseek-forward.sh wait <id>
```

`preflight` finds the launcher, reads the version and resolves the provider
(`deepseek-account` when the desktop app is signed in, else `deepseek-official`
when `DEEPSEEK_API_KEY` is set, else it fails with exit 70). `start` then writes
the patch and task in `${DEEPSEEK_RESCUE_HOME:-$HOME/.deepseek-rescue}/jobs/<id>/`,
appends the constraints paragraph, snapshots git state and launches a wrapper
using `nohup` plus background and `disown`. It prints
`[deepseek-rescue] started job <id>` and exits immediately. The wrapper runs
(on Windows the app exe is called directly, never the
`.cmd` shim, which re-parses arguments through cmd.exe):

```bash
ELECTRON_RUN_AS_NODE=1 DSH_PERMISSION_MODE=workspace-write GIT_TERMINAL_PROMPT=0 \
GIT_SSH_COMMAND="ssh -o BatchMode=yes" \
"<app exe>" --expose-internals "<cli.js>" \
  --profile headless --patch <job>/patch --json [--session-id <id>] - <task on stdin>
```

`wait` feeds only new complete stdout lines to `scripts/stream-filter.js`.
Exit 75 means call `wait <id>` again. Completion prints the remaining progress,
filtered stderr, summary and one `[deepseek-rescue] WARNING: <what changed> —
review before your next git command` line when the run moved `HEAD`, switched
branch, changed the stash list, git config or hooks (it reports, never reverts).
The session id is remembered and temporary job files are cleaned after completion.
To stop a detached job, use `bash scripts/deepseek-forward.sh cancel <id>`.

## Safety model

Facts about headless `dsh` this plugin is built on (verified on 0.2.0-rc.2,
Windows 11):

- The task travels on stdin (`-`), never on the command line, so there is no
  argv length limit.
- `DSH_PERMISSION_MODE` is `read-only`, `workspace-write` (default) or
  `danger-full-access`. `workspace-write` confines writes to the current
  working directory via an OS-level sandbox; a write outside it fails with
  `[sandbox: file access denied under workspace-write mode]`. The approval
  policy is `ask` in both `read-only` and `workspace-write`, and headless has
  no one to answer, so every escalation request fails closed.
- `danger-full-access` means approval `never` and **no sandbox**. The forwarder
  refuses it (exit 64) however it arrives — via `DSH_PERMISSION_MODE` or
  `--permission`.
- The working directory **is** the workspace root (the CLI uses
  `process.cwd()`).
- The sandbox does **not** block network or git inside the workspace (`.git` is
  inside it), so the constraints paragraph still forbids commit, push, reset,
  checkout, clean, branch switching and deleting files.
- `--session-id <id>` resumes an existing persisted session and errors if the
  id is unknown, if the session was recorded in a different working directory,
  or if it is a subagent session. The forwarder remembers the session id of
  each run under `~/.deepseek-rescue/sessions/<sha1 of $PWD>` and `--continue`
  passes it back.

What this does **not** cover — know it before delegating:

- Shell commands run as your OS user and can reach any path on disk. The
  delegate edits your live working tree; do not edit the same files while a
  `--background` run is in flight. Commit or stash your own work first.
- Web fetch and network commands are not denied. Do not delegate tasks that
  process untrusted content.
- A delegate can still commit, switch branch or stash despite the constraints
  paragraph. The forwarder compares `HEAD`, branch, stash, git config and hooks before
  and after and prints a `WARNING` line per change. Treat the paragraph as a
  guardrail, not a sandbox.

## Known DeepSeek CLI behaviours this plugin works around

| Behaviour (0.2.0-rc.2) | Handling |
|---|---|
| `dsh.cmd` passes arguments through `cmd.exe`, which re-parses quotes | the app exe is called directly with `ELECTRON_RUN_AS_NODE=1` and `--expose-internals <cli.js>` |
| `ELECTRON_RUN_AS_NODE=1` turns the app exe into a Node runtime | the stream filter also runs on that exe, so no separate `node` is required |
| No CLI flags for model/provider; the headless profile defaults to `deepseek-official` and fails `MISSING_CREDENTIAL` without `DEEPSEEK_API_KEY` | a temp `--patch` overlay sets the provider (account token → `deepseek-account`) and the model |
| Reasoning tokens stream on stderr as `dsh: reasoning:` | dropped; only `dsh: <CODE>: <message>` lines are kept |
| Headless approval requests have no one to answer and fail closed | the default `workspace-write` and `--read-only` modes never use `danger-full-access` |
| A delegate can commit, switch branch or stash despite the prompt | the forwarder compares git metadata before and after and prints a `WARNING` line per change |
| The `--patch` YAML loader evaluates `!!js` tags | `--model` only accepts a plain slug (`[A-Za-z0-9._-]`, max 64); anything else exits 64 |
| `final` repeats the last assistant text block | the filter prints `final` only when it differs |
| Windows: the shell tool fails with `SetNamedSecurityInfoW failed (Win32 5): grantWrite(<workspace>)` while file edits still work. The sandbox grants itself access to the workspace and needs your user to hold an **explicit** full-control entry on it; owner rights alone (typical for folders outside your profile, like `C:\projects`) are not enough | one-time fix per tree: `icacls C:\projects /grant <you>:(OI)(CI)F` (undo: `icacls C:\projects /remove:g <you>`) |
| Windows: inside the sandbox, MSYS2 programs (Git Bash, `sed`, `grep`…) die at startup with `0xC0000022` | the delegate uses PowerShell; native tools (`git`, `node`, `python`, `dotnet`) work. Ask for PowerShell commands in tasks that must run scripts |

## What's in the plugin

| Piece | Purpose |
|---|---|
| `agents/deepseek-rescue.md` | Thin forwarder subagent — `preflight`, `start` and `wait` calls, output returned as-is |
| `scripts/deepseek-forward.sh` | Launcher discovery, provider/model preflight, patch writing, detached jobs, wait slices, cancellation, session memory, git-change warnings |
| `scripts/stream-filter.js` | `--json` → compact progress log |
| `tests/run.sh` | Hermetic tests with a fake `dsh` — `bash tests/run.sh` |
| `/deepseek:rescue` | Delegate a task explicitly (`--background`, `--wait`, `--model`, `--read-only`, `--continue`) |
| `/deepseek:setup` | Locate CLI, version, provider/sign-in and how to fix each |
| `docs/claude-md-snippet.md` | Ready-to-paste CLAUDE.md block |
| `docs/delegation-guide.md` | Multi-lane orchestration guide |

## Not yet

- The macOS install layout is unverified (`/Applications/DeepSeek Harness.app/...`);
  the forwarder tries it, then falls back to a `dsh` on PATH.
- A Codex CLI skill variant (copilot-plugin-cc ships one).
- A quota gauge: billing is the DeepSeek platform balance, but the CLI exposes
  no headless usage command the forwarder could read before a run.

## License

[MIT](LICENSE)
