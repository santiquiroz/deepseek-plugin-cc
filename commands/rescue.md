---
description: Delegate a well-specified coding task to DeepSeek Harness CLI (dsh) through the deepseek-rescue subagent
argument-hint: "[--background|--wait] [--model <slug>] [--read-only] [--continue] [the task DeepSeek should perform]"
allowed-tools: AskUserQuestion, Agent
---

Invoke the `deepseek:deepseek-rescue` subagent via the `Agent` tool (`subagent_type: "deepseek:deepseek-rescue"`), forwarding the raw user request as the prompt.
`deepseek:deepseek-rescue` is a subagent, not a skill — do not call it via the `Skill` tool. This command runs inline so the `Agent` tool stays in scope.
The final user-visible response must be the subagent's output verbatim.

Raw user request:
$ARGUMENTS

Execution mode:

- If the request includes `--background`, run the subagent in the background and continue other work; relay the result when it completes.
- If the request includes `--wait`, run the subagent in the foreground.
- If neither flag is present, default to foreground.
- `--background` and `--wait` are execution flags for Claude Code. Do not forward them in the prompt, and do not treat them as part of the natural-language task text.
- `--model <slug>`, `--read-only` and `--continue` are runtime flags. Preserve them in the forwarded prompt (the subagent maps them to `dsh` flags and environment), but do not treat them as part of the natural-language task text. Valid slugs: `deepseek-flash` (default, mechanical work) and `deepseek-v4-pro` (reasoning work).

Operating rules:

- The subagent is a thin forwarder only. It calls `preflight`, then `start`, then repeats `wait <id>` while it exits 75. Each is a separate foreground `Bash` call (waits use timeout 600000 ms), never `run_in_background`; the script detaches `dsh` against the current repo and the subagent returns the combined output as-is.
- Runs last up to `DEEPSEEK_RESCUE_MAX_SECONDS` (default 2700 seconds, 45 minutes), awaited in 480-second slices. The call budget is `1 + 1 + ceil(MAX/480) + 1`. If the subagent is interrupted, the job keeps running: retain its started job id and later use `bash "${CLAUDE_PLUGIN_ROOT}/scripts/deepseek-forward.sh" wait <id>` or `cancel <id>` (exit 130). Edits already made remain in the working tree.
- Before dispatching, make sure the task text is self-contained: paste in the file paths, signatures and acceptance criteria it refers to. The delegate does not see this conversation.
- For reviews, diagnoses and second opinions that must not touch the working tree, add `--read-only` (runs `DSH_PERMISSION_MODE=read-only`, which refuses edits).
- Return the output verbatim to the user. Do not paraphrase, summarize, rewrite, or add commentary before or after it.
- Do not ask the subagent to inspect files, monitor progress, summarize output, or do follow-up work of its own.
- If the returned output says `dsh` is not installed or that there are no DeepSeek credentials, tell the user to run `/deepseek:setup`.
- If the returned output starts with `[deepseek-rescue] DeepSeek balance or rate limit hit`, nothing more will run on DeepSeek — hand the task to another delegate (Codex, Copilot, Antigravity, Cursor, Ollama) or take it inline, and say so once. Do not retry automatically.
- If the user did not supply a task, ask what task DeepSeek should perform.
