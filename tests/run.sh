#!/usr/bin/env bash
set -u

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$TEST_DIR/.." && pwd)
FIXTURES="$TEST_DIR/fixtures"
FORWARDER="$ROOT/scripts/deepseek-forward.sh"
FILTER=${1:-}
REAL_GIT=$(command -v git 2>/dev/null || :)
REAL_NODE=$(command -v node 2>/dev/null || :)
REAL_GIT_DIR=${REAL_GIT%/*}
REAL_NODE_DIR=${REAL_NODE%/*}
TOTAL=0
FAILED=0
RUN_COUNT=0
TEST_FAILED=0
CALL_ARGS=()

fail() {
  printf '  FAIL: %s\n' "$1"
  TEST_FAILED=1
}

assert_status() {
  [ "$1" = "$2" ] || fail "$3 (expected exit $1, got $2)"
}

assert_contains() {
  case "$1" in
    *"$2"*) ;;
    *) fail "$3 (missing: $2)" ;;
  esac
}

assert_not_contains() {
  case "$1" in
    *"$2"*) fail "$3 (unexpected: $2)" ;;
    *) ;;
  esac
}

assert_equal() {
  [ "$1" = "$2" ] || fail "$3 (expected '$1', got '$2')"
}

isolate_git() {
  export GIT_CONFIG_NOSYSTEM=1
  export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
  git config --global user.name "DeepSeek Rescue Test"
  git config --global user.email "deepseek-rescue-test@example.com"
}

new_sandbox() {
  SANDBOX=$(mktemp -d)
  export HOME="$SANDBOX"
  export DEEPSEEK_RESCUE_HOME="$HOME/.deepseek-rescue"
  export DSH_HOME="$HOME/.dsh"
  export LOCALAPPDATA="$HOME/AppData/Local"
  export FAKE_DSH_CALLS="$HOME/calls"
  export FAKE_DSH_FIXTURE="$FIXTURES/completed.jsonl"
  mkdir -p "$HOME/bin" "$DEEPSEEK_RESCUE_HOME" "$DSH_HOME" "$LOCALAPPDATA" "$FAKE_DSH_CALLS"
  # Default provider: the desktop app's account token, so `run` resolves without extra setup.
  printf 'version: 1\nrecords:\n  deepseek-account-platform/default:\n    kind: token\n    payload:\n      token: test-token\n' >"$DSH_HOME/.credentials.yaml"
  cp "$TEST_DIR/fake-dsh.sh" "$HOME/bin/dsh"
  chmod +x "$HOME/bin/dsh"
  export DSH_BIN="$HOME/bin/dsh"
  unset DEEPSEEK_API_KEY FAKE_DSH_MODE FAKE_DSH_STDERR FAKE_DSH_EXIT
  unset DEEPSEEK_RESCUE_TIMEOUT DSH_PERMISSION_MODE MSYS_NO_PATHCONV MSYS2_ARG_CONV_EXCL
  unset DEEPSEEK_RESCUE_MAX_SECONDS FAKE_DSH_SLEEP FAKE_DSH_CHILD_PID_FILE
  unset GIT_TERMINAL_PROMPT GIT_SSH_COMMAND ELECTRON_RUN_AS_NODE DSH_RESCUE_META_FILE
  PATH="$HOME/bin:/usr/bin:/bin"
  [ -n "$REAL_GIT_DIR" ] && PATH="$PATH:$REAL_GIT_DIR"
  [ -n "$REAL_NODE_DIR" ] && PATH="$PATH:$REAL_NODE_DIR"
  export PATH
  isolate_git
  mkdir -p "$HOME/repo"
  (
    cd "$HOME/repo" || exit 1
    git init -q &&
      printf '%s\n' 'sandbox' >README.md &&
      git add README.md &&
      git commit -q -m initial
  )
  : >"$HOME/task.txt"
}

invoke_args() {
  LAST_OUTPUT=$(cd "$HOME/repo" && bash "$FORWARDER" "$@" 2>&1)
  LAST_STATUS=$?
}

invoke_file() {
  input_file=$1
  shift
  LAST_OUTPUT=$(cd "$HOME/repo" && bash "$FORWARDER" "$@" <"$input_file" 2>&1)
  LAST_STATUS=$?
}

load_call_args() {
  call_number=$1
  CALL_ARGS=()
  while IFS= read -r -d '' arg; do
    CALL_ARGS[${#CALL_ARGS[@]}]=$arg
  done <"$FAKE_DSH_CALLS/$call_number.args"
}

has_arg() {
  wanted=$1
  for arg in "${CALL_ARGS[@]}"; do
    [ "$arg" = "$wanted" ] && return 0
  done
  return 1
}

arg_value() {
  wanted=$1
  index=0
  while [ "$index" -lt "${#CALL_ARGS[@]}" ]; do
    if [ "${CALL_ARGS[$index]}" = "$wanted" ]; then
      next=$((index + 1))
      [ "$next" -lt "${#CALL_ARGS[@]}" ] && printf '%s' "${CALL_ARGS[$next]}"
      return 0
    fi
    index=$((index + 1))
  done
  return 1
}

assert_arg() {
  has_arg "$1" || fail "$2 (missing argument: $1)"
}

assert_no_arg() {
  if has_arg "$1"; then
    fail "$2 (unexpected argument: $1)"
  fi
}

extract_constraint() {
  constraint_name=$1
  ai_clis=$(sed -n '/^readonly AI_CLIS="/{s/^readonly AI_CLIS="//; s/"$//; p;}' "$FORWARDER")
  template=$(sed -n "/^readonly $constraint_name=\"/{s/^readonly $constraint_name=\"//; s/\"\$//; p;}" "$FORWARDER")
  template=${template//\$AI_CLIS/$ai_clis}
  printf '%s' "$template"
}

assert_env_value() {
  env_file=$1
  env_key=$2
  expected_value=$3
  actual_value=$(sed -n "s/^$env_key=//p" "$env_file")
  assert_equal "$expected_value" "$actual_value" "$env_key environment"
}

test_preflight_account() {
  invoke_args preflight
  assert_status 0 "$LAST_STATUS" "Account-provider preflight"
  assert_contains "$LAST_OUTPUT" '[deepseek-rescue] preflight: dsh 0.2.0-rc.2, provider deepseek-account' "Account preflight line"
  assert_contains "$LAST_OUTPUT" 'model: deepseek-flash' "Default model"
}

test_preflight_api_key() {
  rm -f "$DSH_HOME/.credentials.yaml"
  export DEEPSEEK_API_KEY=x
  invoke_args preflight
  assert_status 0 "$LAST_STATUS" "API-key preflight"
  assert_contains "$LAST_OUTPUT" 'provider deepseek-official' "API-key provider"
}

test_preflight_no_credentials() {
  rm -f "$DSH_HOME/.credentials.yaml"
  unset DEEPSEEK_API_KEY
  invoke_args preflight
  assert_status 70 "$LAST_STATUS" "No-credentials preflight"
  assert_contains "$LAST_OUTPUT" 'no DeepSeek credentials' "No-credentials message"
}

test_preflight_model() {
  invoke_args preflight --model deepseek-v4-pro
  assert_status 0 "$LAST_STATUS" "Named-model preflight"
  assert_contains "$LAST_OUTPUT" 'model: deepseek-v4-pro' "Named model"
}

test_launcher_missing() {
  unset DSH_BIN
  rm "$HOME/bin/dsh"
  invoke_args preflight
  assert_status 127 "$LAST_STATUS" "Missing-launcher preflight"
  assert_contains "$LAST_OUTPUT" 'dsh not found' "Missing-launcher message"
}

# The real install: an Electron exe plus resources/app.asar (cli.js lives inside the archive).
test_launcher_app_layout() {
  local app_dir="$LOCALAPPDATA/Programs/DeepSeek Harness"
  unset DSH_BIN
  rm "$HOME/bin/dsh"
  mkdir -p "$app_dir/resources"
  : >"$app_dir/resources/app.asar"
  cat >"$app_dir/DeepSeek Harness.exe" <<FAKE_APP
#!/usr/bin/env bash
case \${1:-} in
  --expose-internals) shift 2; exec bash "$TEST_DIR/fake-dsh.sh" "\$@" ;;
  *.js) exec node "\$@" ;;
esac
exit 99
FAKE_APP
  chmod +x "$app_dir/DeepSeek Harness.exe"
  invoke_args preflight
  assert_status 0 "$LAST_STATUS" "App-layout preflight"
  assert_contains "$LAST_OUTPUT" 'preflight: dsh 0.2.0-rc.2' "App-layout version"
  printf '%s\n' 'task' >"$HOME/task.txt"
  invoke_file "$HOME/task.txt" run
  assert_status 0 "$LAST_STATUS" "App-layout run"
  assert_contains "$LAST_OUTPUT" 'I created hello.txt with the requested content.' "App-layout filtered output"
  assert_env_value "$FAKE_DSH_CALLS/1.env" ELECTRON_RUN_AS_NODE 1
}

test_tricky_task() {
  task=$(cat "$FIXTURES/tricky-task.txt")
  constraints=$(extract_constraint CONSTRAINTS)
  expected_prompt=$(printf '%s\n\n%s' "$task" "$constraints")
  invoke_file "$FIXTURES/tricky-task.txt" run
  assert_status 0 "$LAST_STATUS" "Tricky-task run"
  actual_prompt=$(cat "$FAKE_DSH_CALLS/1.stdin")
  assert_equal "$expected_prompt" "$actual_prompt" "Forwarded tricky task on stdin"
}

test_run_flags() {
  printf '%s\n' 'flags' >"$HOME/task.txt"
  invoke_file "$HOME/task.txt" run
  assert_status 0 "$LAST_STATUS" "Default run"
  load_call_args 1
  assert_arg --profile "Profile flag"
  assert_equal headless "$(arg_value --profile)" "Profile value"
  assert_arg --patch "Patch flag"
  assert_arg --json "JSON flag"
  assert_arg - "Stdin task marker"
  assert_no_arg --session-id "Default session id flag"

  invoke_file "$HOME/task.txt" run --read-only
  assert_status 0 "$LAST_STATUS" "Read-only run"
  load_call_args 2
  read_only_constraints=$(extract_constraint READ_ONLY_CONSTRAINTS)
  expected_prompt=$(printf '%s\n\n%s' 'flags' "$read_only_constraints")
  assert_equal "$expected_prompt" "$(cat "$FAKE_DSH_CALLS/2.stdin")" "Read-only prompt constraints"
}

test_run_patch() {
  printf '%s\n' 'patch' >"$HOME/task.txt"
  invoke_file "$HOME/task.txt" run
  assert_status 0 "$LAST_STATUS" "Patch run"
  patch_content=$(cat "$FAKE_DSH_CALLS/1.patch")
  assert_contains "$patch_content" 'provider: deepseek-account' "Patch provider"
  assert_contains "$patch_content" 'model: deepseek-flash' "Patch model"
  assert_contains "$patch_content" 'reasoningEffort: high' "Patch reasoning effort"

  invoke_file "$HOME/task.txt" run --model deepseek-v4-pro
  assert_status 0 "$LAST_STATUS" "Named-model patch run"
  assert_contains "$(cat "$FAKE_DSH_CALLS/2.patch")" 'model: deepseek-v4-pro' "Patch named model"
}

test_run_env() {
  printf '%s\n' 'env' >"$HOME/task.txt"
  invoke_file "$HOME/task.txt" run
  assert_status 0 "$LAST_STATUS" "Environment run"
  env_file="$FAKE_DSH_CALLS/1.env"
  assert_env_value "$env_file" DSH_PERMISSION_MODE 'workspace-write'
  assert_env_value "$env_file" GIT_TERMINAL_PROMPT 0
  assert_env_value "$env_file" GIT_SSH_COMMAND 'ssh -o BatchMode=yes'
  assert_env_value "$env_file" MSYS2_ARG_CONV_EXCL ''
  assert_env_value "$env_file" MSYS_NO_PATHCONV ''
  assert_env_value "$env_file" ELECTRON_RUN_AS_NODE ''

  invoke_file "$HOME/task.txt" run --read-only
  assert_status 0 "$LAST_STATUS" "Read-only environment run"
  assert_env_value "$FAKE_DSH_CALLS/2.env" DSH_PERMISSION_MODE 'read-only'
}

test_progress_log() {
  printf '%s\n' 'progress' >"$HOME/task.txt"
  invoke_file "$HOME/task.txt" run
  assert_status 0 "$LAST_STATUS" "Progress run"
  assert_contains "$LAST_OUTPUT" '  > write hello.txt' "Started write tool call"
  assert_contains "$LAST_OUTPUT" '  x write: Error: [sandbox: file access denied under workspace-write mode]' "Denied write"
  assert_not_contains "$LAST_OUTPUT" 'escalation available' "Denied write second-line truncation"
  assert_not_contains "$LAST_OUTPUT" 'Planning the edit.' "Thinking stream dropped"
  assert_contains "$LAST_OUTPUT" 'Done, wrote hello.txt.' "Assistant text"
  assert_contains "$LAST_OUTPUT" 'I created hello.txt with the requested content.' "Final answer"
  assert_contains "$LAST_OUTPUT" '[deepseek-rescue] done in' "Done summary"
  assert_contains "$LAST_OUTPUT" 'session session-abc123, tokens 12538/164' "Token totals"
  assert_contains "$LAST_OUTPUT" '[deepseek-rescue] exit 0' "Run exit status"
}

test_missing_credential() {
  export FAKE_DSH_FIXTURE="$FIXTURES/missing-credential.jsonl"
  export FAKE_DSH_STDERR="$FIXTURES/missing-credential.stderr"
  export FAKE_DSH_EXIT=1
  printf '%s\n' 'task' >"$HOME/task.txt"
  invoke_file "$HOME/task.txt" run
  assert_status 1 "$LAST_STATUS" "Missing-credential run"
  assert_contains "$LAST_OUTPUT" 'dsh: MISSING_CREDENTIAL: Missing credential' "Missing-credential stderr"
  assert_contains "$LAST_OUTPUT" '[deepseek-rescue] error in' "Error summary"
  assert_contains "$LAST_OUTPUT" '[deepseek-rescue] exit 1' "Exit passthrough"
}

test_insufficient_balance() {
  export FAKE_DSH_FIXTURE="$FIXTURES/insufficient-balance.jsonl"
  export FAKE_DSH_STDERR="$FIXTURES/insufficient-balance.stderr"
  export FAKE_DSH_EXIT=1
  printf '%s\n' 'task' >"$HOME/task.txt"
  invoke_file "$HOME/task.txt" run
  assert_status 1 "$LAST_STATUS" "Insufficient-balance run"
  assert_contains "$LAST_OUTPUT" 'dsh: INSUFFICIENT_BALANCE: Insufficient Balance' "Insufficient-balance stderr"
}

test_continue() {
  printf '%s\n' 'first task' >"$HOME/task.txt"
  invoke_file "$HOME/task.txt" run
  assert_status 0 "$LAST_STATUS" "First run"
  printf '%s\n' 'second task' >"$HOME/task.txt"
  invoke_file "$HOME/task.txt" run --continue
  assert_status 0 "$LAST_STATUS" "Continue run"
  load_call_args 2
  assert_arg --session-id "Session id flag"
  assert_equal 'session-abc123' "$(arg_value --session-id)" "Remembered session id"
}

test_continue_without_session() {
  printf '%s\n' 'task' >"$HOME/task.txt"
  invoke_file "$HOME/task.txt" run --continue
  assert_status 64 "$LAST_STATUS" "Continue without session"
  assert_contains "$LAST_OUTPUT" 'no remembered session' "Continue-without-session message"
  [ ! -e "$FAKE_DSH_CALLS/1.args" ] || fail "Continue without session invoked the fake launcher"
}

test_refuse_danger_flag() {
  printf '%s\n' 'task' >"$HOME/task.txt"
  invoke_file "$HOME/task.txt" run --permission danger-full-access
  assert_status 64 "$LAST_STATUS" "Danger flag refusal"
  assert_contains "$LAST_OUTPUT" 'danger-full-access' "Danger flag message"
  [ ! -e "$FAKE_DSH_CALLS/1.args" ] || fail "Danger flag invoked the fake launcher"
}

test_invalid_model() {
  printf '%s
' 'task' >"$HOME/task.txt"
  invoke_file "$HOME/task.txt" run --model '!!js process.exit()'
  assert_status 64 "$LAST_STATUS" "Invalid model refusal"
  assert_contains "$LAST_OUTPUT" 'invalid model slug' "Invalid model message"
  [ ! -e "$FAKE_DSH_CALLS/1.args" ] || fail "Invalid model invoked the fake launcher"
}

test_final_not_repeated() {
  export FAKE_DSH_FIXTURE="$FIXTURES/completed-same-final.jsonl"
  printf '%s
' 'task' >"$HOME/task.txt"
  invoke_file "$HOME/task.txt" run
  assert_status 0 "$LAST_STATUS" "Same-final run"
  assert_equal 1 "$(printf '%s
' "$LAST_OUTPUT" | grep -c 'All done.')" "Final answer printed once"
}

test_refuse_danger_env() {
  export DSH_PERMISSION_MODE=danger-full-access
  printf '%s\n' 'task' >"$HOME/task.txt"
  invoke_file "$HOME/task.txt" run
  assert_status 64 "$LAST_STATUS" "Danger env refusal"
  assert_contains "$LAST_OUTPUT" 'danger-full-access' "Danger env message"
}

test_unknown_flag() {
  printf '%s\n' 'task' >"$HOME/task.txt"
  invoke_file "$HOME/task.txt" run --frobnicate
  assert_status 64 "$LAST_STATUS" "Unknown flag"
}

test_empty_task() {
  printf ' \n\t\n' >"$HOME/task.txt"
  invoke_file "$HOME/task.txt" run
  assert_status 64 "$LAST_STATUS" "Empty-task run"
  [ ! -e "$FAKE_DSH_CALLS/1.args" ] || fail "Empty task invoked the fake launcher"
}

test_timeout() {
  if ! command -v timeout >/dev/null 2>&1 &&
    ! command -v gtimeout >/dev/null 2>&1 &&
    ! command -v perl >/dev/null 2>&1; then
    printf 'SKIP timeout (no timeout, gtimeout, or perl)\n'
    return
  fi
  printf '%s\n' 'sleep' >"$HOME/task.txt"
  export DEEPSEEK_RESCUE_TIMEOUT=2 FAKE_DSH_MODE=sleep
  invoke_file "$HOME/task.txt" run
  case "$LAST_STATUS" in
    124 | 137 | 142) ;;
    *) fail "Timeout run returned unexpected exit $LAST_STATUS" ;;
  esac
  assert_contains "$LAST_OUTPUT" 'timed out after' "Timeout message"
}

test_git_warning() {
  printf '%s\n' 'commit' >"$HOME/task.txt"
  export FAKE_DSH_MODE=commit
  invoke_file "$HOME/task.txt" run
  assert_status 0 "$LAST_STATUS" "Commit-mode run"
  assert_contains "$LAST_OUTPUT" '[deepseek-rescue] WARNING: HEAD moved' "Git HEAD warning"
}

test_manifests() {
  plugin_version=$(sed -n 's/.*"version": "\([^"]*\)".*/\1/p' "$ROOT/.claude-plugin/plugin.json" | head -n 1)
  marketplace_versions=$(sed -n 's/.*"version": "\([^"]*\)".*/\1/p' "$ROOT/.claude-plugin/marketplace.json")
  changelog_version=$(sed -n 's/^## \([^ ]*\).*/\1/p' "$ROOT/CHANGELOG.md" | head -n 1)
  assert_equal "$plugin_version" "$changelog_version" "Plugin and changelog versions"
  assert_equal "$plugin_version" "$(printf '%s\n' "$marketplace_versions" | sed -n '1p')" "Marketplace metadata version"
  assert_equal "$plugin_version" "$(printf '%s\n' "$marketplace_versions" | sed -n '2p')" "Marketplace plugin version"
}

start_job() {
  printf '%s\n' 'detached task' >"$HOME/task.txt"
  invoke_file "$HOME/task.txt" start "$@"
  assert_status 0 "$LAST_STATUS" "Detached start"
  JOB_ID=$(printf '%s\n' "$LAST_OUTPUT" | sed -n 's/^\[deepseek-rescue\] started job //p')
  [ -n "$JOB_ID" ] || fail "Start returned no job id"
  JOB_DIR="$DEEPSEEK_RESCUE_HOME/jobs/$JOB_ID"
}

await_file() {
  local attempt=0
  while [ ! -f "$1" ] && [ "$attempt" -lt 100 ]; do
    sleep 0.1
    attempt=$((attempt + 1))
  done
  [ -f "$1" ] || fail "Fake launcher did not create $1"
}

assert_child_stopped() {
  local child_pid attempt=0
  child_pid=$(cat "$FAKE_DSH_CHILD_PID_FILE")
  while kill -0 "$child_pid" 2>/dev/null && [ "$attempt" -lt 30 ]; do
    sleep 0.1
    attempt=$((attempt + 1))
  done
  if kill -0 "$child_pid" 2>/dev/null; then
    fail "Detached child process $child_pid survived termination"
  fi
}

test_start_metadata() {
  export FAKE_DSH_MODE=sleep FAKE_DSH_SLEEP=30
  start_job --model deepseek-v4-pro --read-only
  assert_not_contains "$LAST_OUTPUT" 'done in' "Start returns before job completion"
  for file in pid workspace started deadline git-before patch task; do
    [ -s "$JOB_DIR/$file" ] || fail "Missing job metadata $file"
  done
  [ ! -e "$JOB_DIR/exit" ] || fail "Start waited for sleeping job"
  assert_equal 2700 "$(( $(cat "$JOB_DIR/deadline") - $(cat "$JOB_DIR/started") ))" "Default job deadline"
  await_file "$FAKE_DSH_CALLS/1.patch"
  load_call_args 1
  assert_arg --json "Detached JSON flag"
  assert_arg --patch "Detached patch flag"
  assert_contains "$(cat "$FAKE_DSH_CALLS/1.patch")" 'model: deepseek-v4-pro' "Detached named model"
  assert_env_value "$FAKE_DSH_CALLS/1.env" DSH_PERMISSION_MODE read-only
  assert_contains "$(cat "$FAKE_DSH_CALLS/1.stdin")" "$(extract_constraint READ_ONLY_CONSTRAINTS)" "Detached read-only constraints"
  invoke_args cancel "$JOB_ID"
  assert_status 130 "$LAST_STATUS" "Metadata job cleanup"
}

test_wait_partial_progress() {
  export FAKE_DSH_MODE=partial FAKE_DSH_SLEEP=10
  start_job
  await_file "$FAKE_DSH_CALLS/partial-ready"
  invoke_args wait "$JOB_ID" --slice 1
  assert_status 75 "$LAST_STATUS" "Running slice"
  assert_contains "$LAST_OUTPUT" 'First progress.' "Initial progress"
  assert_contains "$LAST_OUTPUT" '  > write split.txt' "Initial tool call"
  assert_contains "$LAST_OUTPUT" "job $JOB_ID still running" "Running slice message"
  assert_not_contains "$LAST_OUTPUT" 'Trailing' "Incomplete JSON remains buffered"
  [ -s "$JOB_DIR/offset" ] || fail "Wait did not persist stdout offset"
  invoke_args wait "$JOB_ID" --slice 15
  assert_status 0 "$LAST_STATUS" "Completed later slice"
  assert_not_contains "$LAST_OUTPUT" 'First progress.' "Earlier progress not repeated"
  assert_not_contains "$LAST_OUTPUT" '  > write split.txt' "Earlier tool call not repeated"
  assert_contains "$LAST_OUTPUT" 'Trailing progress.' "Incomplete JSON completed"
  assert_equal 1 "$(printf '%s\n' "$LAST_OUTPUT" | grep -c 'Trailing progress.')" "Final deduplication across slices"
  assert_contains "$LAST_OUTPUT" '  x write: Denied split write' "Tool name retained across slices"
  assert_contains "$LAST_OUTPUT" 'session session-partial, tokens 30/5' "Cumulative session and tokens"
  assert_contains "$LAST_OUTPUT" '[deepseek-rescue] done in' "Completed summary"
  assert_contains "$LAST_OUTPUT" '[deepseek-rescue] exit 0' "Completed exit"
  for file in task patch; do
    [ ! -e "$JOB_DIR/$file" ] || fail "Finished job retained $file"
  done
  invoke_args wait "$JOB_ID"
  assert_status 0 "$LAST_STATUS" "Cached completed wait"
  assert_contains "$LAST_OUTPUT" 'session session-partial, tokens 30/5' "Cached completed summary"
  assert_not_contains "$LAST_OUTPUT" 'Trailing progress.' "Cached wait does not replay progress"
  printf '%s\n' 'continue detached' >"$HOME/task.txt"
  export FAKE_DSH_MODE=ok
  invoke_file "$HOME/task.txt" start --continue
  assert_status 0 "$LAST_STATUS" "Detached continue"
  JOB_ID=$(printf '%s\n' "$LAST_OUTPUT" | sed -n 's/^\[deepseek-rescue\] started job //p')
  invoke_args wait "$JOB_ID" --slice 10
  assert_status 0 "$LAST_STATUS" "Detached continued completion"
  load_call_args 2
  assert_equal session-partial "$(arg_value --session-id)" "Detached remembered session"
}

test_wait_workspace_warning() {
  export FAKE_DSH_MODE=commit
  export FAKE_DSH_STDERR="$FIXTURES/missing-credential.stderr"
  start_job
  LAST_OUTPUT=$(cd "$HOME" && bash "$FORWARDER" wait "$JOB_ID" --slice 10 2>&1)
  LAST_STATUS=$?
  assert_status 0 "$LAST_STATUS" "Wait outside job workspace"
  assert_contains "$LAST_OUTPUT" '[deepseek-rescue] WARNING: HEAD moved' "Detached workspace HEAD warning"
  assert_contains "$LAST_OUTPUT" 'dsh: MISSING_CREDENTIAL: Missing credential' "Detached filtered stderr"
  assert_contains "$LAST_OUTPUT" '[deepseek-rescue] exit 0' "Detached warning exit"
}

test_wait_final_without_newline() {
  printf '%s\n' '{"type":"session","sessionId":"session-no-newline"}' >"$HOME/no-newline.jsonl"
  printf '%s' '{"type":"final","text":"Final without a newline."}' >>"$HOME/no-newline.jsonl"
  export FAKE_DSH_FIXTURE="$HOME/no-newline.jsonl"
  start_job
  invoke_args wait "$JOB_ID" --slice 10
  assert_status 0 "$LAST_STATUS" "Completed unterminated JSON"
  assert_contains "$LAST_OUTPUT" 'Final without a newline.' "Unterminated final preserved"
  assert_contains "$LAST_OUTPUT" 'session session-no-newline' "Unterminated final session"
}

test_wait_nonzero_exit() {
  export FAKE_DSH_FIXTURE="$FIXTURES/missing-credential.jsonl"
  export FAKE_DSH_STDERR="$FIXTURES/missing-credential.stderr"
  export FAKE_DSH_EXIT=1
  start_job
  invoke_args wait "$JOB_ID" --slice 10
  assert_status 1 "$LAST_STATUS" "Detached failure passthrough"
  assert_contains "$LAST_OUTPUT" 'dsh: MISSING_CREDENTIAL: Missing credential' "Detached failure stderr"
  assert_contains "$LAST_OUTPUT" '[deepseek-rescue] error in' "Detached failure summary"
  assert_contains "$LAST_OUTPUT" 'session session-missing' "Detached failure session"
  assert_contains "$LAST_OUTPUT" '[deepseek-rescue] exit 1' "Detached failure exit"
  invoke_args wait "$JOB_ID"
  assert_status 1 "$LAST_STATUS" "Cached detached failure"
  assert_contains "$LAST_OUTPUT" '[deepseek-rescue] error in' "Cached failure summary"
  assert_not_contains "$LAST_OUTPUT" 'dsh: MISSING_CREDENTIAL' "Cached failure does not replay stderr"
}

test_wait_relative_home() {
  export DEEPSEEK_RESCUE_HOME=.relative-rescue
  start_job
  JOB_DIR="$HOME/repo/$DEEPSEEK_RESCUE_HOME/jobs/$JOB_ID"
  [ -s "$JOB_DIR/workspace" ] || fail "Relative job home did not create workspace metadata"
  invoke_args wait "$JOB_ID" --slice 10
  assert_status 0 "$LAST_STATUS" "Relative job-home completion"
  assert_contains "$LAST_OUTPUT" '[deepseek-rescue] done in' "Relative job-home summary"
  assert_contains "$LAST_OUTPUT" '[deepseek-rescue] exit 0' "Relative job-home exit"
  [ -f "$JOB_DIR/finished" ] || fail "Relative job home did not persist completion"
  [ ! -e "$JOB_DIR/task" ] || fail "Relative job home did not clean task"
  invoke_args wait "$JOB_ID"
  assert_status 0 "$LAST_STATUS" "Relative job-home cached completion"
}

test_wait_deadline_tree() {
  export FAKE_DSH_MODE=sleep FAKE_DSH_SLEEP=30 DEEPSEEK_RESCUE_MAX_SECONDS=2
  export FAKE_DSH_CHILD_PID_FILE="$HOME/child.pid"
  start_job
  assert_equal 2 "$(( $(cat "$JOB_DIR/deadline") - $(cat "$JOB_DIR/started") ))" "Configured deadline"
  await_file "$FAKE_DSH_CHILD_PID_FILE"
  invoke_args wait "$JOB_ID" --slice 10
  assert_status 124 "$LAST_STATUS" "Detached deadline"
  assert_contains "$LAST_OUTPUT" 'timed out after' "Detached timeout summary"
  assert_contains "$LAST_OUTPUT" 'edits made until then are in the working tree' "Detached timeout edits message"
  assert_contains "$LAST_OUTPUT" '[deepseek-rescue] exit 124' "Detached timeout exit"
  assert_child_stopped
  invoke_args wait "$JOB_ID"
  assert_status 124 "$LAST_STATUS" "Cached deadline status"
}

test_cancel_tree() {
  export FAKE_DSH_MODE=sleep FAKE_DSH_SLEEP=30
  export FAKE_DSH_CHILD_PID_FILE="$HOME/child.pid"
  start_job
  await_file "$FAKE_DSH_CHILD_PID_FILE"
  invoke_args cancel "$JOB_ID"
  assert_status 130 "$LAST_STATUS" "Detached cancel"
  assert_contains "$LAST_OUTPUT" '[deepseek-rescue] exit 130' "Cancelled exit"
  assert_child_stopped
  invoke_args wait "$JOB_ID"
  assert_status 130 "$LAST_STATUS" "Cached cancelled status"
}

test_detached_invalid_arguments() {
  invoke_args wait unknown-job
  assert_status 64 "$LAST_STATUS" "Unknown wait id"
  invoke_args cancel unknown-job
  assert_status 64 "$LAST_STATUS" "Unknown cancel id"
  invoke_args wait
  assert_status 64 "$LAST_STATUS" "Missing wait id"
  invoke_args wait ../escape
  assert_status 64 "$LAST_STATUS" "Unsafe wait id"
  printf '%s\n' 'invalid detached' >"$HOME/task.txt"
  invoke_file "$HOME/task.txt" start --continue
  assert_status 64 "$LAST_STATUS" "Detached continue without session"
  invoke_file "$HOME/task.txt" start --model '!!js invalid'
  assert_status 64 "$LAST_STATUS" "Detached invalid model"
  invoke_file "$HOME/task.txt" start --frobnicate
  assert_status 64 "$LAST_STATUS" "Detached unknown option"
  start_job
  for slice in 0 541 invalid; do
    invoke_args wait "$JOB_ID" --slice "$slice"
    assert_status 64 "$LAST_STATUS" "Invalid wait slice $slice"
  done
  invoke_args wait "$JOB_ID" --frobnicate
  assert_status 64 "$LAST_STATUS" "Unknown wait option"
  invoke_args wait "$JOB_ID" --slice 10
  assert_status 0 "$LAST_STATUS" "Validation job completion"
}

run_case() {
  test_name=$1
  test_function=$2
  if [ -n "$FILTER" ] && [ "$FILTER" != "$test_name" ] && [ "$FILTER" != "$test_function" ]; then
    return
  fi
  RUN_COUNT=$((RUN_COUNT + 1))
  TOTAL=$((TOTAL + 1))
  TEST_FAILED=0
  new_sandbox
  "$test_function"
  if [ "$TEST_FAILED" -eq 0 ]; then
    printf 'PASS %s\n' "$test_name"
  else
    printf 'FAIL %s\n' "$test_name"
    FAILED=$((FAILED + 1))
  fi
}

run_case preflight-account test_preflight_account
run_case preflight-api-key test_preflight_api_key
run_case preflight-no-credentials test_preflight_no_credentials
run_case preflight-model test_preflight_model
run_case launcher-missing test_launcher_missing
run_case tricky-task test_tricky_task
run_case run-flags test_run_flags
run_case run-patch test_run_patch
run_case run-env test_run_env
run_case progress-log test_progress_log
run_case missing-credential test_missing_credential
run_case insufficient-balance test_insufficient_balance
run_case continue test_continue
run_case continue-without-session test_continue_without_session
run_case refuse-danger-flag test_refuse_danger_flag
run_case refuse-danger-env test_refuse_danger_env
run_case launcher-app-layout test_launcher_app_layout
run_case invalid-model test_invalid_model
run_case final-not-repeated test_final_not_repeated
run_case unknown-flag test_unknown_flag
run_case empty-task test_empty_task
run_case timeout test_timeout
run_case git-warning test_git_warning
run_case start-metadata test_start_metadata
run_case wait-partial-progress test_wait_partial_progress
run_case wait-workspace-warning test_wait_workspace_warning
run_case wait-final-without-newline test_wait_final_without_newline
run_case wait-nonzero-exit test_wait_nonzero_exit
run_case wait-relative-home test_wait_relative_home
run_case wait-deadline-tree test_wait_deadline_tree
run_case cancel-tree test_cancel_tree
run_case detached-invalid-arguments test_detached_invalid_arguments
run_case manifests test_manifests

if [ "$RUN_COUNT" -eq 0 ]; then
  printf 'FAIL no test matched filter: %s\n' "$FILTER"
  exit 1
fi
printf '%s/%s tests passed\n' "$((TOTAL - FAILED))" "$TOTAL"
[ "$FAILED" -eq 0 ]
