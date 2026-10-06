# Changelog

## 0.2.0 — 2026-10-06

- Detached `start` jobs and `wait` slices let delegations run up to
  `DEEPSEEK_RESCUE_MAX_SECONDS` (default 2700 seconds, 45 minutes) beyond the
  Bash tool's 600-second foreground limit. The unchanged `run` command keeps
  its 9-minute cap for short calls.
- Incremental progress survives slice boundaries, including partial JSON
  lines; completion retains session memory, summaries and git-change warnings.
- `cancel <id>` stops the process tree with exit 130; an expired deadline
  stops it with exit 124. Interrupted subagents leave the job running for a
  later `wait` or `cancel` call.
- The subagent uses separate foreground `preflight`, `start` and repeated
  `wait` calls instead of a single long Bash call.

## 0.1.0 — 2026-01-15

First release, verified against DeepSeek Harness desktop app 0.2.0-rc.2
(Windows 11, Git Bash).

- `deepseek-rescue` subagent: a thin forwarder that runs
  `dsh --profile headless --patch <tmp> --json -` with the task on stdin, an
  explicit provider/model patch, a 9-minute `timeout`, and returns a compact
  progress log built from `--json`, so a run cut by the timeout still shows
  what it did.
- Provider selection: the desktop app's account token (`deepseek-account`)
  when present, else `DEEPSEEK_API_KEY` (`deepseek-official`), else preflight
  fails with exit 70.
- Windows: calls the app exe directly with `ELECTRON_RUN_AS_NODE=1` and
  `--expose-internals <cli.js>` (never the `.cmd` shim, which re-parses
  arguments through cmd.exe); a macOS layout and a `dsh` on PATH are also
  tried.
- `--read-only` maps to `DSH_PERMISSION_MODE=read-only`; the default sandbox
  is `workspace-write`, and `danger-full-access` is refused with exit 64.
- Session memory under `~/.deepseek-rescue/sessions/<sha1 of $PWD>`, so
  `--continue` resumes the last delegated run via `--session-id`.
- `run` compares `HEAD`, branch, stash, git config and hooks before and after
  and prints a `WARNING` line per change.
- `/deepseek:rescue` and `/deepseek:setup` commands, CLAUDE.md snippet and
  delegation guide.
