---
description: Check that DeepSeek Harness CLI (dsh) is installed and that a provider (account token or DEEPSEEK_API_KEY) is available
argument-hint: ""
allowed-tools: Bash, Read, Edit, Write, AskUserQuestion
---

Run these steps in order and finish with one consolidated status block. Never print token, API key or credential values.

`FORWARD` below means `bash "${CLAUDE_PLUGIN_ROOT}/scripts/deepseek-forward.sh"` — the same script the `deepseek-rescue` subagent runs, so setup checks exactly what delegation will hit.

Step 1 — Probe

```bash
FORWARD preflight
```

Read the exit code and act, then rerun Step 1 after any fix (at most three times in total):

- **127** (`dsh not found`) → use `AskUserQuestion` exactly once: `Install DeepSeek Harness (Recommended)` / `Skip for now`. Install by downloading the desktop app from the DeepSeek site and signing in; the forwarder locates the per-user Electron install at `%LOCALAPPDATA%\Programs\DeepSeek Harness\DeepSeek Harness.exe` and calls it directly with `ELECTRON_RUN_AS_NODE=1` and `--expose-internals <cli.js>` (never the `.cmd` shim, which re-parses arguments through cmd.exe). On macOS it tries `/Applications/DeepSeek Harness.app/...` (unverified) and then a `dsh` on PATH. If the user skips, jump to the report.
- **70** (`no DeepSeek credentials`) → tell the user to open DeepSeek Harness and sign in once (the account token is read from `${DSH_HOME:-$HOME/.dsh}/.credentials.yaml`), or to export an API key as `DEEPSEEK_API_KEY`. Then rerun `/deepseek:setup`.
- **0** → note the `dsh <version>, provider <provider>` line and continue with Step 2.

Step 2 — Version

There is no published version floor yet; this plugin was verified against DeepSeek Harness desktop app **0.2.0-rc.2**. Report the version from Step 1 as-is.

Step 3 — Consolidated report

One short block: launcher and version, provider in use (account token vs API key), and how to delegate (`/deepseek:rescue <task>`, `/deepseek:rescue --read-only <review task with the diff pasted>`, `/deepseek:rescue --model deepseek-v4-pro <reasoning task>`, or let the `deepseek-rescue` subagent fire proactively).

Safety reminder to state once: every delegated run is sandboxed to the working directory by default (`DSH_PERMISSION_MODE=workspace-write`); `--read-only` refuses edits; `danger-full-access` is never used.
