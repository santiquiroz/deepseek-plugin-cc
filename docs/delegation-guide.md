# Delegation Guide

How to make Claude Code delegate work to DeepSeek Harness CLI (this plugin),
so the main Claude thread stays focused on the work only it can do. Claude
Code stays the orchestrator.

## What to delegate

DeepSeek takes bounded, fully specified tasks — mechanical work on
`deepseek-flash`, reasoning work on `deepseek-v4-pro`, and read-only second
opinions with `--read-only`. Everything on the never-delegate list stays
inline with Claude.

## The core split

| Kind of work | How | Examples |
|---|---|---|
| Mechanical work | `deepseek-flash` (default) | One spec file, a rename, boilerplate, one build fix |
| Reasoning work | `deepseek-v4-pro` (via `--model`) | Deep diagnosis, architecture-adjacent code |
| Second opinion | `--read-only` review of a pasted diff or file | Review a tricky change, cross-check a diagnosis |
| Keep inline (never delegate) | Tasks where the WHY lives in your conversation | Domain logic, business rules, architecture and feature design |

Rule of thumb: if the delegate needs to understand *why*, keep it inline. If
it is bounded and fully specified, delegate it to DeepSeek.

## Writing the task

- Self-contained: file paths, signatures, expected behaviour, acceptance
  checks (the exact test command to run). The delegate does not see your
  conversation.
- One deliverable per run.
- For `--read-only`, paste the code or the diff into the task: read-only runs
  refuse edits, so the delegate cannot run `git diff` itself.

## The parallel pattern

```
Claude: writes SomeHandler (domain logic — inline, never delegated)
  → /deepseek:rescue --background "add unit tests for src/utils/money.ts (signatures below) ..."
  → /deepseek:rescue --background --read-only "review this diff for race conditions: <diff>"
Claude: continues with the next task while delegations run
```

- WIP cap: 3–5 concurrent background delegations. Never run two delegates on
  the same files at the same time.
- Kill-switch: after 3 stuck or failed iterations on the same task, stop
  retrying it; report it and take it inline or choose another path.

## Safety rules

- The subagent calls `preflight`, then `start`, then `wait <id>` repeatedly
  while it exits 75. Each call is foreground and separate; waits use a
  600000 ms Bash timeout and never `run_in_background`. The script detaches
  the job and waits in 480-second slices (maximum 540).
- `DEEPSEEK_RESCUE_MAX_SECONDS` sets the deadline (default 2700 seconds,
  45 minutes). Budget at most `1 + 1 + ceil(MAX/480) + 1` Bash calls.
  The old 9-minute cap kept a single foreground call below the Bash tool's
  600-second ceiling; the unchanged `run` remains that short path.
- If the subagent is interrupted, the job keeps running. Retain its started
  job id to call `bash "${CLAUDE_PLUGIN_ROOT}/scripts/deepseek-forward.sh" wait <id>`
  or `cancel <id>` later. Cancellation stops the process tree with exit 130;
  a wait past the deadline stops it with exit 124. Existing edits remain.

- Every delegated run is sandboxed to the working directory
  (`DSH_PERMISSION_MODE=workspace-write` by default); writes outside it fail
  closed. `--read-only` refuses edits. `danger-full-access` is never used.
- The sandbox does not block git inside the workspace, so the constraints
  paragraph still forbids commit, push, reset, checkout, clean, branch
  switching and deleting files. Treat that as a guardrail, not a sandbox.
- Review `git status`, `git diff`, `git log` and `git stash list` after every
  run. The orchestrator owns the commit.
- Do not delegate tasks that process untrusted content (web pages, issue
  text from strangers): network commands are available to the delegate.

## Fallback

**Detection:** the subagent prints `[deepseek-rescue] DeepSeek balance or rate
limit hit` when the output mentions `Insufficient Balance`, `402`, `rate
limit`, `429`, `quota`, `MISSING_CREDENTIAL`, `401` or `Authentication`.
Billing is the user's DeepSeek platform balance (pay-as-you-go): there is no
weekly pool and no free headless usage meter.

1. **Balance or rate limit hit** → nothing more runs on DeepSeek this period.
   Stop and report it so the user can choose another path. Never retry in a
   loop.
2. **Missing credentials** → the user signs in to DeepSeek Harness once or
   exports `DEEPSEEK_API_KEY`; then `/deepseek:setup`.
3. **Delegation keeps failing** → stop auto-delegating for the rest of the
   session, handle everything inline, and mention it once.

Tell the user in one line when a fallback happened — that DeepSeek could not
run the task and where it went instead.

## Second opinions, not second drafts

Use `--read-only` when a tricky change or an ambiguous diagnosis benefits
from an independent pass. Feed it the same self-contained contract and the
code or diff, compare the answer with your own, and reconcile in the main
thread.

## Using it with other delegates

This plugin assumes no ordering against any other delegate: it only forwards
tasks to `dsh` and reports the result. If you run several delegates, you decide
the order, triggers and workload split in your own `CLAUDE.md`.
