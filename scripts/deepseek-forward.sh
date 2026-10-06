#!/usr/bin/env bash
# Usage:
#   deepseek-forward.sh preflight [--model <slug>]
#   deepseek-forward.sh run [--model <slug>] [--read-only] [--continue] <task on stdin>
set -u

readonly USAGE_EXIT=64
readonly PREFLIGHT_FAILED_EXIT=70
readonly NOT_FOUND_EXIT=127
readonly DEFAULT_MODEL=deepseek-flash
readonly DANGEROUS_PERMISSION=danger-full-access
readonly SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
readonly RESCUE_HOME=${DEEPSEEK_RESCUE_HOME:-$HOME/.deepseek-rescue}
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
    ELECTRON_RUN_AS_NODE=1 "$APP_EXE" "$(filter_script_path)"
  elif node_bin=$(command -v node 2>/dev/null); then
    "$node_bin" "$(filter_script_path)"
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
    *) usage_error "usage: deepseek-forward.sh preflight|run [options]" ;;
  esac
}

main "$@"
