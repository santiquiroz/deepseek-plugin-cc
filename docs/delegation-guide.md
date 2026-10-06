# Multi-Agent Delegation Guide

How to make Claude Code delegate work to DeepSeek Harness CLI (this plugin) as
the **first lane** next to whatever other delegates you run — so the main Claude
thread stays focused on the work only it can do. Claude Code stays the
orchestrator.

## Which setup do you have?

- **DeepSeek next to other lanes** (a reasoning lane such as the codex plugin, a
  mechanical one such as the copilot plugin, extra agentic lanes such as the
  cursor plugin): DeepSeek takes bounded mechanical and reasoning tasks first,
  and the other lanes absorb what is left over or out of DeepSeek's reach.
- **DeepSeek alone**: DeepSeek takes every delegable bounded task.

Everything on the never-delegate list stays inline with Claude in both cases.

## The core split

| Lane | Owns | Examples |
|---|---|---|
| **DeepSeek (this plugin)** | The preferred first lane: mechanical work on `deepseek-flash`, reasoning work on `deepseek-v4-pro`; read-only second opinions | One spec file, a rename, boilerplate, one build fix (`deepseek-flash`); deep diagnosis, architecture-adjacent code (`deepseek-v4-pro`); `--read-only` review of a pasted diff |
| **Reasoning delegate** (e.g. Codex) | Fallback for deep diagnosis, multi-step build fixing | Complex build errors after a failed fix, multi-file refactors changing control flow |
| **Mechanical delegate** (e.g. Copilot) | Fallback for purely mechanical, zero-domain-context work | CRUD/mapping specs, renames across 3+ files, dead-code cleanup |
| **Extra agentic lane** (e.g. Cursor) | Fallback bounded tasks, second opinions | Bounded tasks when the first lanes are out of quota |
| **Keep inline (never delegate)** | Tasks where the WHY lives in your conversation | Domain logic, business rules, architecture and feature design |

Rule of thumb: if the delegate needs to understand *why*, keep it inline. If
it is bounded and fully specified, delegate it — to DeepSeek first.

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

- WIP cap: 3–5 concurrent background delegations across all lanes. Never run
  two delegates on the same files at the same time.
- Kill-switch: after 3 stuck or failed iterations on the same task, stop
  retrying that lane; hand the task to another lane once or take it inline.

## Safety rules

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

## Fallback chain

**Detection:** the subagent prints `[deepseek-rescue] DeepSeek balance or rate
limit hit` when the output mentions `Insufficient Balance`, `402`, `rate
limit`, `429`, `quota`, `MISSING_CREDENTIAL`, `401` or `Authentication`.
Billing is the user's DeepSeek platform balance (pay-as-you-go): there is no
weekly pool and no free headless usage meter.

1. **Balance or rate limit hit** → nothing more runs on DeepSeek this period.
   Hand the task to another lane once (Codex, Copilot, Antigravity, Cursor,
   Ollama) if it fits, otherwise do it inline. Never retry in a loop.
2. **Missing credentials** → the user signs in to DeepSeek Harness once or
   exports `DEEPSEEK_API_KEY`; then `/deepseek:setup`.
3. **Every lane exhausted** → stop auto-delegating for the rest of the
   session, handle everything inline, and mention it once.

Tell the user in one line when a fallback happened — which lane failed and
which one picked the task up, or that Claude took over inline.

## Second opinions, not second drafts

Use `--read-only` when a tricky change or an ambiguous diagnosis benefits
from an independent pass. Feed it the same self-contained contract and the
code or diff, compare the answer with your own, and reconcile in the main
thread.
