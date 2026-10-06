#!/usr/bin/env bash
# Usage:
#   deepseek-forward.sh preflight [--model <slug>]
#   deepseek-forward.sh run [--model <slug>] [--read-only] [--continue] <task on stdin>
#   deepseek-forward.sh start [--model <slug>] [--read-only] [--continue] <task on stdin>
#   deepseek-forward.sh wait <id> [--slice <seconds>]
#   deepseek-forward.sh cancel <id>
set -u

readonly USAGE_EXIT=64
readonly PREFLIGHT_FAILED_EXIT=70
readonly NOT_FOUND_EXIT=127
readonly DEFAULT_MODEL=deepseek-flash
readonly DANGEROUS_PERMISSION=danger-full-access
readonly SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
readonly RESCUE_HOME=$(rescue_home=${DEEPSEEK_RESCUE_HOME:-$HOME/.deepseek-rescue};
  if command -v cygpath >/dev/null 2>&1; then cygpath -au "$rescue_home";
  elif [[ $rescue_home = /* ]]; then printf '%s' "$rescue_home";
  else printf '%s/%s' "$PWD" "$rescue_home"; fi)
readonly AI_CLIS="claude, codex, copilot, agy, gemini, ollama, cursor-agent, dsh"
readonly CONSTRAINTS="Constraints: work directly in this workspace following the instructions above. Do not invoke other AI CLIs ($AI_CLIS). Do not commit, push, reset, checkout, clean, switch branches or delete files. If a command is denied by policy, stop and report it — do not look for another way to run it. Leave your changes in the working tree and end with a short list of the files you touched."
readonly READ_ONLY_CONSTRAINTS="Constraints: this is a read-only run: do not edit files; report findings and proposed changes as text. Do not invoke other AI CLIs ($AI_CLIS). If a command is denied by policy, stop and report it — do not look for another way to run it."

LAUNCH_MODE=""    # electron | bin
APP_EXE=""
CLI_JS=""
AGENT_BIN=""
OPT_MODEL=""
OPT_READ_ONLY=0
OPT_CONTINUE=0
PROVIDER=""

usage_error() {
  printf 'deepseek-forward.sh: %s\n' "$1" >&2
  exit "$USAGE_EXIT"
}

refuse_dangerous() {
  printf 'deepseek-forward.sh: refusing to run with permission mode danger-full-access — it disables the sandbox and auto-approves every action. Use the default workspace-write, or pass --read-only.\n' >&2
  exit "$USAGE_EXIT"
}

# The forwarder never runs under danger-full-access, however the request arrives.
guard_permission() {
  [ "${DSH_PERMISSION_MODE:-}" = "$DANGEROUS_PERMISSION" ] && refuse_dangerous
  return 0
}

# The model lands in the --patch YAML, whose loader evaluates `!!js` tags: only plain slugs get through.
validate_model() {
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || usage_error "invalid model slug: $1"
}

parse_options() {
  while [ $# -gt 0 ]; do
    case $1 in
      --model)
        [ $# -ge 2 ] || usage_error "--model needs a value"
        validate_model "$2"
        OPT_MODEL=$2
        shift 2
        ;;
      --read-only) OPT_READ_ONLY=1; shift ;;
      --continue) OPT_CONTINUE=1; shift ;;
      --permission)
        [ $# -ge 2 ] || usage_error "--permission needs a value"
        [ "$2" = "$DANGEROUS_PERMISSION" ] && refuse_dangerous
        usage_error "unsupported option: --permission"
        ;;
      *) usage_error "unknown option: $1" ;;
    esac
  done
}

native_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

# cli.js lives inside app.asar (an archive Electron reads natively), so the file to check is app.asar.
# The Windows .cmd shim passes arguments through cmd.exe, which re-parses quotes; the forwarder calls
# the app exe directly with ELECTRON_RUN_AS_NODE=1 and --expose-internals <cli.js>, exactly like the shim.
find_launcher() {
  local app_exe cli_js
  if [ -n "${DSH_BIN:-}" ]; then
    LAUNCH_MODE=bin
    AGENT_BIN=$DSH_BIN
    return 0
  fi
  app_exe="${LOCALAPPDATA:-}/Programs/DeepSeek Harness/DeepSeek Harness.exe"
  cli_js="${LOCALAPPDATA:-}/Programs/DeepSeek Harness/resources/app.asar/dsh/node_modules/@deepseek-ai/dsh-desktop-host/lib/cli.js"
  if [ -n "${LOCALAPPDATA:-}" ] && [ -f "$app_exe" ] && [ -f "${cli_js%%/app.asar/*}/app.asar" ]; then
    LAUNCH_MODE=electron
    APP_EXE=$app_exe
    CLI_JS=$cli_js
    return 0
  fi
  # macOS layout (unverified) — see README.
  app_exe="/Applications/DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness"
  cli_js="/Applications/DeepSeek Harness.app/Contents/Resources/app.asar/dsh/node_modules/@deepseek-ai/dsh-desktop-host/lib/cli.js"
  if [ -f "$app_exe" ] && [ -f "${cli_js%%/app.asar/*}/app.asar" ]; then
    LAUNCH_MODE=electron
    APP_EXE=$app_exe
    CLI_JS=$cli_js
    return 0
  fi
  if command -v dsh >/dev/null 2>&1; then
    LAUNCH_MODE=bin
    AGENT_BIN=$(command -v dsh)
    return 0
  fi
  return 1
}

require_launcher() {
  find_launcher && return 0
  echo "deepseek-rescue: dsh not found — install DeepSeek Harness (or set DSH_BIN), then run /deepseek:setup"
  return "$NOT_FOUND_EXIT"
}

credentials_file() {
  printf '%s' "${DSH_HOME:-$HOME/.dsh}/.credentials.yaml"
}

account_token_present() {
  local file
  file=$(credentials_file)
  [ -r "$file" ] || return 1
  # The token sits in nested keys under this record, never on the same line.
  grep -Eq '^[[:space:]]*deepseek-account-platform/default:' "$file"
}

resolve_provider() {
  if account_token_present; then
    PROVIDER=deepseek-account
    return 0
  fi
  if [ -n "${DEEPSEEK_API_KEY:-}" ]; then
    PROVIDER=deepseek-official
    return 0
  fi
  return 1
}

provider_error() {
  printf '[deepseek-rescue] preflight failed: no DeepSeek credentials — open DeepSeek Harness and sign in once (account token), or export DEEPSEEK_API_KEY, then run /deepseek:setup\n'
  return "$PREFLIGHT_FAILED_EXIT"
}

launcher_argv() {
  if [ "$LAUNCH_MODE" = electron ]; then
    printf '%s\0' "$APP_EXE" --expose-internals "$CLI_JS"
  else
    printf '%s\0' "$AGENT_BIN"
  fi
}

permission_mode() {
  if [ "$OPT_READ_ONLY" = 1 ]; then printf 'read-only'; else printf 'workspace-write'; fi
}

# Child env: explicit sandbox mode, git helpers, and no MSYS path-conversion overrides (the task goes
# on stdin, so the patch path must convert normally). ELECTRON_RUN_AS_NODE only applies to the app exe.
dsh_env() {
  unset MSYS_NO_PATHCONV MSYS2_ARG_CONV_EXCL
  export DSH_PERMISSION_MODE=$(permission_mode) GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="ssh -o BatchMode=yes"
  if [ "$LAUNCH_MODE" = electron ]; then
    export ELECTRON_RUN_AS_NODE=1
  fi
}

run_dsh() {
  local launcher=() item
  while IFS= read -r -d '' item; do launcher+=("$item"); done < <(launcher_argv)
  ( dsh_env; "${launcher[@]}" "$@" )
}

timeout_argv() {
  local seconds=${DEEPSEEK_RESCUE_TIMEOUT:-540} bin
  if bin=$(command -v timeout || command -v gtimeout); then printf '%s\0' "$bin" -k 10 "$seconds"; return 0; fi
  command -v perl >/dev/null 2>&1 && printf '%s\0' perl -e 'alarm shift; exec @ARGV' "$seconds"
}

filter_script_path() {
  if [ "$LAUNCH_MODE" = electron ]; then native_path "$SCRIPT_DIR/stream-filter.js"; else printf '%s' "$SCRIPT_DIR/stream-filter.js"; fi
}

# ELECTRON_RUN_AS_NODE=1 turns the app exe into a Node runtime, so the stream filter runs on it too;
# otherwise fall back to node from PATH (DSH_BIN points at a fake in tests).
filter_output() {
  local node_bin
  if [ "$LAUNCH_MODE" = electron ]; then
    ELECTRON_RUN_AS_NODE=1 "$APP_EXE" "$(filter_script_path)" "$@"
  elif node_bin=$(command -v node 2>/dev/null); then
    "$node_bin" "$(filter_script_path)" "$@"
  else
    cat
  fi
}

patch_path() {
  if [ "$LAUNCH_MODE" = electron ]; then native_path "$1"; else printf '%s' "$1"; fi
}

write_patch() {
  local file=$1 model=${OPT_MODEL:-$DEFAULT_MODEL}
  {
    printf '%s\n' '- id: agent-default-model'
    printf '%s\n' '  name: "@deepseek-ai/dsh-agent-default-model"'
    printf '%s\n' '  config:'
    printf '%s\n' "    provider: $PROVIDER"
    printf '%s\n' "    model: $model"
    printf '%s\n' '    reasoningEffort: high'
  } >"$file"
}

build_prompt() {
  local constraints=$CONSTRAINTS
  [ "$OPT_READ_ONLY" = 1 ] && constraints=$READ_ONLY_CONSTRAINTS
  printf '%s\n\n%s' "$1" "$constraints"
}

sha1_of() {
  if command -v sha1sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha1sum | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum | cut -d' ' -f1
  elif command -v openssl >/dev/null 2>&1; then
    printf '%s' "$1" | openssl dgst -sha1 | sed 's/^.*=[[:space:]]*//'
  else
    printf '%s' "$1" | cksum | cut -d' ' -f1
  fi
}

session_file() {
  printf '%s/sessions/%s' "$RESCUE_HOME" "$(sha1_of "$PWD")"
}

remembered_session() {
  local file id
  file=$(session_file)
  [ -r "$file" ] || return 1
  IFS= read -r id <"$file"
  [ -n "$id" ] || return 1
  printf '%s' "$id"
}

remember_session() {
  local id=$1 dir
  [ -n "$id" ] || return 0
  dir=$(dirname "$(session_file)")
  mkdir -p "$dir" || return 0
  printf '%s\n' "$id" >"$(session_file)"
}

preflight() {
  local version
  require_launcher || return
  version=$(run_dsh --version 2>&1 | tr -d '\r' | sed -n '1p')
  resolve_provider || { provider_error; return "$PREFLIGHT_FAILED_EXIT"; }
  printf '[deepseek-rescue] preflight: dsh %s, provider %s\n' "${version:-unknown}" "$PROVIDER"
  printf 'model: %s\n' "${OPT_MODEL:-$DEFAULT_MODEL}"
}

read_task() {
  local task
  task=$(cat)
  [ -n "${task//[[:space:]]/}" ] || usage_error "no task on stdin"
  printf '%s' "$task"
}

dsh_args() {
  local patch_file=$1 session=$2
  printf '%s\0' --profile headless --patch "$(patch_path "$patch_file")" --json
  [ -n "$session" ] && printf '%s\0' --session-id "$session"
  printf '%s\0' -
}

# The dsh CLI streams reasoning tokens on stderr as `dsh: reasoning: ...`; drop those and keep the
# real `dsh: <CODE>: <message>` status/error lines.
print_stderr() {
  local file=$1 line
  while IFS= read -r line; do
    case $line in
      dsh:\ reasoning:*) : ;;
      dsh:*) printf '%s\n' "$line" ;;
    esac
  done <"$file"
}

report_exit() {
  case $1 in
    124 | 137 | 142) echo "[deepseek-rescue] timed out after ${DEEPSEEK_RESCUE_TIMEOUT:-540}s — edits made until then are in the working tree" ;;
  esac
  echo "[deepseek-rescue] exit $1"
}

run_task() {
  local task session="" session_id tokens_in tokens_out launcher=() limiter=() args=() item before rc elapsed start end
  task=$(read_task) || return
  require_launcher || return
  resolve_provider || { provider_error; return "$PREFLIGHT_FAILED_EXIT"; }
  if [ "$OPT_CONTINUE" = 1 ]; then
    if ! session=$(remembered_session); then
      printf '[deepseek-rescue] --continue requested but no remembered session for %s — run once without --continue first\n' "$PWD" >&2
      return "$USAGE_EXIT"
    fi
  fi
  # These stay global so the EXIT trap (which fires after run_task returns) can still see them.
  patch_file=$(mktemp) || return 1
  task_file=$(mktemp) || return 1
  stderr_file=$(mktemp) || return 1
  meta_file=$(mktemp) || return 1
  trap 'rm -f "$patch_file" "$task_file" "$stderr_file" "$meta_file"' EXIT
  write_patch "$patch_file" || return 1
  build_prompt "$task" >"$task_file"
  while IFS= read -r -d '' item; do launcher+=("$item"); done < <(launcher_argv)
  while IFS= read -r -d '' item; do limiter+=("$item"); done < <(timeout_argv)
  while IFS= read -r -d '' item; do args+=("$item"); done < <(dsh_args "$patch_file" "$session")
  before=$(git_state) || before=""
  # The filter runs under node (app exe or PATH), so hand it the native path to the meta file; the
  # shell keeps reading the POSIX path.
  export DSH_RESCUE_META_FILE=$(native_path "$meta_file")
  start=$(date +%s)
  ( dsh_env; "${limiter[@]}" "${launcher[@]}" "${args[@]}" <"$task_file" 2>"$stderr_file" ) | filter_output
  rc=${PIPESTATUS[0]}
  end=$(date +%s)
  elapsed=$((end - start))
  print_stderr "$stderr_file"
  session_id=$(sed -n '1p' "$meta_file" 2>/dev/null)
  tokens_in=$(sed -n '2p' "$meta_file" 2>/dev/null)
  tokens_out=$(sed -n '3p' "$meta_file" 2>/dev/null)
  : "${tokens_in:=0}" "${tokens_out:=0}"
  if [ "$rc" -eq 0 ]; then
    printf '[deepseek-rescue] done in %ss, session %s, tokens %s/%s\n' "$elapsed" "${session_id:-unknown}" "$tokens_in" "$tokens_out"
  else
    printf '[deepseek-rescue] error in %ss, session %s, tokens %s/%s\n' "$elapsed" "${session_id:-unknown}" "$tokens_in" "$tokens_out"
  fi
  remember_session "$session_id"
  warn_git_changes "$before"
  report_exit "$rc"
  return "$rc"
}

positive_seconds() {
  [[ $2 =~ ^[0-9]{1,8}$ ]] || usage_error "$1 needs positive integer seconds"
  [ "$((10#$2))" -gt 0 ] || usage_error "$1 needs positive integer seconds"
}

job_path() {
  [[ $1 =~ ^[A-Za-z0-9_-]+$ ]] || usage_error "unknown job: $1"
  [ -d "$RESCUE_HOME/jobs/$1" ] || usage_error "unknown job: $1"
  printf '%s/jobs/%s' "$RESCUE_HOME" "$1"
}

write_job_argv() {
  local job=$1 session=$2
  { launcher_argv; dsh_args "$job/patch" "$session"; } >"$job/argv"
  printf '%s\n' "$LAUNCH_MODE" >"$job/launcher-mode"
  printf '%s\n' "$APP_EXE" >"$job/app-exe"
  if [ "$LAUNCH_MODE" != electron ]; then command -v node >"$job/node-bin"; fi
}

detach_job() {
  local job=$1 pid
  ( dsh_env; nohup bash "$SCRIPT_DIR/deepseek-forward.sh" __job "$job" </dev/null >"$job/wrapper-log" 2>&1 &
    pid=$!
    printf '%s\n' "$pid" >"$job/pid"
    disown "$pid"
  )
}

run_job_wrapper() {
  local job=$1 argv=() item rc
  while IFS= read -r -d '' item; do argv+=("$item"); done <"$job/argv"
  "${argv[@]}" <"$job/task" >"$job/stdout" 2>"$job/stderr"
  rc=$?
  date +%s >"$job/ended"
  printf '%s\n' "$rc" >"$job/exit.tmp"
  mv "$job/exit.tmp" "$job/exit"
  return "$rc"
}

start_task() {
  local task session="" max_seconds=${DEEPSEEK_RESCUE_MAX_SECONDS:-2700} job id started
  task=$(read_task) || return
  require_launcher || return
  resolve_provider || { provider_error; return "$PREFLIGHT_FAILED_EXIT"; }
  positive_seconds DEEPSEEK_RESCUE_MAX_SECONDS "$max_seconds"
  if [ "$OPT_CONTINUE" = 1 ]; then
    session=$(remembered_session) || {
      printf '[deepseek-rescue] --continue requested but no remembered session for %s — run once without --continue first\n' "$PWD" >&2
      return "$USAGE_EXIT"
    }
  fi
  if [ "$LAUNCH_MODE" != electron ] && ! command -v node >/dev/null 2>&1; then
    printf '[deepseek-rescue] start requires node to filter progress across waits\n' >&2
    return "$NOT_FOUND_EXIT"
  fi
  mkdir -p "$RESCUE_HOME/jobs" || return 1
  id="$(date -u +%Y%m%dT%H%M%SZ)-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
  job="$RESCUE_HOME/jobs/$id"
  mkdir "$job" || return 1
  started=$(date +%s)
  printf '%s\n' "$(native_path "$PWD")" >"$job/workspace"
  printf '%s\n' "$started" >"$job/started"
  printf '%s\n' "$((started + 10#$max_seconds))" >"$job/deadline"
  printf '0\n' >"$job/offset"
  : >"$job/stdout"
  : >"$job/stderr"
  git_state >"$job/git-before" || :
  write_patch "$job/patch" || return 1
  build_prompt "$task" >"$job/task"
  write_job_argv "$job" "$session"
  detach_job "$job" || return 1
  printf '[deepseek-rescue] started job %s\n' "$id"
}

job_filter() {
  local job=$1 node_bin
  shift
  LAUNCH_MODE=$(cat "$job/launcher-mode")
  APP_EXE=$(cat "$job/app-exe")
  if [ "$LAUNCH_MODE" = electron ]; then filter_output "$@"; return; fi
  node_bin=$(cat "$job/node-bin")
  "$node_bin" "$SCRIPT_DIR/stream-filter.js" "$@"
}

print_job_progress() {
  local job=$1 final=${2:-} statuses=()
  export DSH_RESCUE_META_FILE=$(native_path "$job/meta")
  export DSH_RESCUE_STATE_FILE=$(native_path "$job/filter-state")
  export DSH_RESCUE_OFFSET_FILE=$(native_path "$job/offset")
  job_filter "$job" --read-slice "$(native_path "$job/stdout")" "$(native_path "$job/offset")" "$final" | job_filter "$job"
  statuses=("${PIPESTATUS[@]}")
  [ "${statuses[0]}" -eq 0 ] && [ "${statuses[1]}" -eq 0 ]
}

windows_pid() {
  ps -p "$1" -l | awk 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == "WINPID") column = i; next } column { print $column; exit }'
}

kill_descendants() {
  local pid=$1 child children
  children=$(ps -e -o pid=,ppid= 2>/dev/null | awk -v parent="$pid" '$2 == parent { print $1 }')
  for child in $children; do kill_descendants "$child"; done
  kill -KILL "$pid" 2>/dev/null || :
}

kill_windows_tree() {
  local pid=$1 taskkill_bin=$2 children child native_pid
  # MSYS fork children can have native parents outside taskkill's tree.
  children=$(ps -e | awk -v parent="$pid" 'NR > 1 && $2 == parent { print $1 }')
  for child in $children; do kill_windows_tree "$child" "$taskkill_bin" || return 1; done
  native_pid=$(windows_pid "$pid")
  [ -n "$native_pid" ] || return 0
  "$taskkill_bin" //T //F //PID "$native_pid" >/dev/null 2>&1 && return 0
  kill -0 "$pid" 2>/dev/null && return 1
  return 0
}

kill_job_tree() {
  local job=$1 pid taskkill_bin
  pid=$(cat "$job/pid")
  [[ $pid =~ ^[0-9]+$ ]] || return 1
  case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN*)
      taskkill_bin=$(command -v taskkill) || taskkill_bin=$(cygpath -u "${SYSTEMROOT:-${WINDIR:-C:/Windows}}/System32/taskkill.exe")
      kill_windows_tree "$pid" "$taskkill_bin"
      ;;
    *) kill_descendants "$pid" ;;
  esac
}

mark_job_stopped() {
  local job=$1 rc=$2
  kill_job_tree "$job" || return 1
  date +%s >"$job/ended"
  printf '%s\n' "$rc" >"$job/exit"
  [ "$rc" = 124 ] && printf 'timeout\n' >"$job/stopped"
  return 0
}

write_job_summary() {
  local job=$1 rc=$2 elapsed=$3 session_id tokens_in tokens_out status=error
  session_id=$(sed -n '1p' "$job/meta" 2>/dev/null)
  tokens_in=$(sed -n '2p' "$job/meta" 2>/dev/null)
  tokens_out=$(sed -n '3p' "$job/meta" 2>/dev/null)
  [ "$rc" = 0 ] && status=done
  printf '[deepseek-rescue] %s in %ss, session %s, tokens %s/%s\n' "$status" "$elapsed" "${session_id:-unknown}" "${tokens_in:-0}" "${tokens_out:-0}" >"$job/summary"
  if [ -f "$job/stopped" ]; then
    printf '[deepseek-rescue] timed out after %ss — edits made until then are in the working tree\n' "$(($(cat "$job/deadline") - $(cat "$job/started")))" >>"$job/summary"
  fi
}

finish_job_workspace() {
  local job=$1 workspace session_id
  workspace=$(cat "$job/workspace")
  cd "$workspace" || { git_warning "the job workspace is no longer readable"; return 0; }
  session_id=$(sed -n '1p' "$job/meta" 2>/dev/null)
  remember_session "$session_id"
  warn_git_changes "$(cat "$job/git-before")"
}

clean_job() {
  local job=$1
  rm -f "$job/patch" "$job/task" "$job/argv" "$job/stdout" "$job/stderr" "$job/meta" "$job/filter-state" "$job/filter-state.tmp" "$job/offset" "$job/offset.pending" "$job/git-before" "$job/launcher-mode" "$job/app-exe" "$job/node-bin" "$job/wrapper-log" "$job/exit.tmp"
}

finish_job() {
  local job=$1 rc elapsed
  rc=$(cat "$job/exit")
  if [ -f "$job/finished" ]; then cat "$job/summary"; return "$rc"; fi
  print_job_progress "$job" final || return 1
  elapsed=$(($(cat "$job/ended") - $(cat "$job/started")))
  print_stderr "$job/stderr"
  write_job_summary "$job" "$rc" "$elapsed"
  cat "$job/summary"
  ( finish_job_workspace "$job" )
  printf '[deepseek-rescue] exit %s\n' "$rc" | tee -a "$job/summary"
  clean_job "$job"
  : >"$job/finished"
  return "$rc"
}

parse_slice() {
  [ $# -eq 0 ] && { printf '480'; return 0; }
  [ $# -eq 2 ] && [ "$1" = --slice ] || usage_error "usage: deepseek-forward.sh wait <id> [--slice <seconds>]"
  positive_seconds --slice "$2"
  [ "$((10#$2))" -le 540 ] || usage_error "--slice must be at most 540 seconds"
  printf '%s' "$((10#$2))"
}

wait_job() {
  local id=${1:-} job slice slice_end deadline now elapsed
  [ $# -gt 0 ] || usage_error "wait needs a job id"
  shift
  job=$(job_path "$id") || return "$USAGE_EXIT"
  slice=$(parse_slice "$@") || return "$USAGE_EXIT"
  slice_end=$(($(date +%s) + slice))
  deadline=$(cat "$job/deadline")
  while :; do
    [ -f "$job/exit" ] && { finish_job "$job"; return $?; }
    now=$(date +%s)
    if [ "$now" -ge "$deadline" ]; then
      mark_job_stopped "$job" 124 || return 1
      finish_job "$job"
      return $?
    fi
    print_job_progress "$job" || return 1
    if [ "$now" -ge "$slice_end" ]; then
      elapsed=$((now - $(cat "$job/started")))
      printf '[deepseek-rescue] job %s still running (%ss) — call wait again\n' "$id" "$elapsed"
      return 75
    fi
    sleep 1
  done
}

cancel_job() {
  local job
  [ $# -eq 1 ] || usage_error "cancel needs a job id"
  job=$(job_path "$1") || return "$USAGE_EXIT"
  [ -f "$job/exit" ] || mark_job_stopped "$job" 130 || return 1
  finish_job "$job"
}

git_paths() {
  git rev-parse --path-format=absolute --git-dir --git-common-dir --git-path hooks 2>/dev/null
}

files_fingerprint() {
  local files=("$@") existing=() file
  for file in "${files[@]}"; do
    [ -f "$file" ] && existing+=("$file")
  done
  [ ${#existing[@]} -gt 0 ] || { printf 'none'; return 0; }
  cksum "${existing[@]}" | cksum
}

hooks_fingerprint() {
  local hooks=("$1"/*)
  files_fingerprint "${hooks[@]}"
}

stash_count() {
  git rev-list --walk-reflogs --count refs/stash -- 2>/dev/null || printf '0'
}

# Read-only: no command here touches the index, runs hooks or starts a pager.
git_state() {
  local git_dir common hooks
  { IFS= read -r git_dir && IFS= read -r common && IFS= read -r hooks; } < <(git_paths) || return 1
  printf 'HEAD\t%s\n' "$(git rev-parse -q --verify HEAD || printf 'none')"
  printf 'branch\t%s\n' "$(git symbolic-ref -q --short HEAD || printf 'detached')"
  printf 'stash\t%s\n' "$(stash_count)"
  printf 'config\t%s\n' "$(files_fingerprint "$common/config" "$git_dir/config.worktree")"
  printf 'hooks\t%s\n' "$(hooks_fingerprint "$hooks")"
}

state_field() {
  local key=$1 line
  while IFS= read -r line; do
    [ "${line%%$'\t'*}" = "$key" ] && { printf '%s' "${line#*$'\t'}"; return 0; }
  done <<<"$2"
  return 1
}

describe_git_change() {
  local key=$1 before=$2 after=$3
  case $key in
    HEAD) printf 'HEAD moved from %s to %s' "${before:0:12}" "${after:0:12}" ;;
    branch) printf 'branch changed from %s to %s' "$before" "$after" ;;
    stash) printf 'stash list changed from %s to %s entries' "$before" "$after" ;;
    config) printf 'git config changed (.git/config)' ;;
    hooks) printf 'git hooks changed (.git/hooks or core.hooksPath)' ;;
  esac
}

git_warning() {
  printf '[deepseek-rescue] WARNING: %s — review before your next git command\n' "$1"
}

# Reports what the delegate changed in git metadata; never reverts it.
warn_git_changes() {
  local before=$1 after key old new
  [ -n "$before" ] || return 0
  after=$(git_state) || { git_warning "the git repository is no longer readable"; return 0; }
  while IFS=$'\t' read -r key old; do
    new=$(state_field "$key" "$after")
    [ "$old" = "$new" ] || git_warning "$(describe_git_change "$key" "$old" "$new")"
  done <<<"$before"
}

main() {
  local command=${1:-}
  [ $# -gt 0 ] && shift
  guard_permission
  case $command in
    preflight) parse_options "$@"; preflight ;;
    run) parse_options "$@"; run_task ;;
    start) parse_options "$@"; start_task ;;
    wait) wait_job "$@" ;;
    cancel) cancel_job "$@" ;;
    __job) run_job_wrapper "$@" ;;
    *) usage_error "usage: deepseek-forward.sh preflight|run|start|wait|cancel [options]" ;;
  esac
}

main "$@"
