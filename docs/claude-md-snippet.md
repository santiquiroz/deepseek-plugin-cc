# CLAUDE.md snippet

Paste the block below into your `~/.claude/CLAUDE.md` (or a project
`CLAUDE.md`) to make Claude Code delegate to DeepSeek proactively. Adjust the
trigger table to your own rules — the block only describes this delegate. If
you run several delegates, define their order and triggers here as well, in
your own words. See [delegation-guide.md](delegation-guide.md) for the full
split.

```markdown
# DeepSeek Harness CLI delegation (deepseek plugin)

DeepSeek Harness (`dsh`) handles bounded coding tasks. Subagent
`deepseek:deepseek-rescue`; commands `/deepseek:rescue`, `/deepseek:setup`.
The delegate reads and edits files and runs commands in the repo, sandboxed
to the working directory (`DSH_PERMISSION_MODE=workspace-write`), with the
constraints paragraph forbidding commit, push, reset, checkout, clean,
branch switching and deleting files. `deepseek-flash` for mechanical work,
`deepseek-v4-pro` for reasoning.

| Trigger | Action |
|---|---|
| Mechanical or bounded task (spec file, rename, boilerplate, one build fix) | `deepseek:deepseek-rescue` in background on `deepseek-flash` |
| Reasoning task (deep diagnosis, architecture-adjacent code) | `deepseek:deepseek-rescue` in background on `deepseek-v4-pro` |
| Independent read-only second opinion — review code, cross-check a diagnosis | `deepseek:deepseek-rescue` in background with `--read-only`; paste the diff or code into the task (read-only does not run shell commands) |
| Output starts with `[deepseek-rescue] DeepSeek balance or rate limit hit`, or a `MISSING_CREDENTIAL`/auth error | Nothing more will run on DeepSeek. Stop and report it so the user can choose another path, and say so once |

Never delegate: domain logic, business rules, architecture decisions,
anything where the WHY lives in this conversation.

Rules:
- The task text must be self-contained — file paths, signatures, acceptance
  criteria. The delegate does not see this conversation.
- Keep tasks small: one run is capped at 9 minutes.
- Review `git status` and `git diff` before committing; the orchestrator owns
  the commit.
- Run `/deepseek:setup` once per machine to verify the install and sign-in.
- Launch in the background and keep working. WIP cap 3–5 concurrent
  delegations. Kill-switch: 3 failed iterations on the same task → stop
  retrying it and report.
- If several delegates are in use, their order is defined here by the user;
  this block assumes none.
```
