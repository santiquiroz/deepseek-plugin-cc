#!/usr/bin/env bash
set -u

if [ "${1:-}" = --version ]; then
  printf '%s\n' '0.2.0-rc.2'
  exit 0
fi

FAKE_DSH_CALLS=${FAKE_DSH_CALLS:-}
patch_file=""
prev=""
for arg in "$@"; do
  if [ "$prev" = --patch ]; then patch_file=$arg; prev=""; fi
  case $arg in
    --patch) prev=--patch ;;
    --session-id) prev=--session-id ;;
  esac
done

if [ -n "$FAKE_DSH_CALLS" ]; then
  mkdir -p "$FAKE_DSH_CALLS"
  call_number=1
  while [ -e "$FAKE_DSH_CALLS/$call_number.args" ]; do
    call_number=$((call_number + 1))
  done
  printf '%s\0' "$@" >"$FAKE_DSH_CALLS/$call_number.args"
  {
    printf 'DSH_PERMISSION_MODE=%s\n' "${DSH_PERMISSION_MODE-}"
    printf 'GIT_TERMINAL_PROMPT=%s\n' "${GIT_TERMINAL_PROMPT-}"
    printf 'GIT_SSH_COMMAND=%s\n' "${GIT_SSH_COMMAND-}"
    printf 'ELECTRON_RUN_AS_NODE=%s\n' "${ELECTRON_RUN_AS_NODE-}"
    printf 'MSYS2_ARG_CONV_EXCL=%s\n' "${MSYS2_ARG_CONV_EXCL-}"
    printf 'MSYS_NO_PATHCONV=%s\n' "${MSYS_NO_PATHCONV-}"
  } >"$FAKE_DSH_CALLS/$call_number.env"
  cat >"$FAKE_DSH_CALLS/$call_number.stdin"
  if [ -n "$patch_file" ] && [ -f "$patch_file" ]; then
    cp "$patch_file" "$FAKE_DSH_CALLS/$call_number.patch"
  fi
fi

case "${FAKE_DSH_MODE:-ok}" in
  sleep)
    sleep "${FAKE_DSH_SLEEP:-30}" &
    child_pid=$!
    if [ -n "${FAKE_DSH_CHILD_PID_FILE:-}" ]; then
      printf '%s\n' "$child_pid" >"$FAKE_DSH_CHILD_PID_FILE"
    fi
    wait "$child_pid"
    exit 0
    ;;
  partial)
    printf '%s\n' '{"type":"session","sessionId":"session-partial"}'
    printf '%s\n' '{"type":"tool_call","callId":"split-call","tool":"write","input":{"path":"split.txt"}}'
    printf '%s\n' '{"type":"status","phase":"step_end","usage":{"inputTokens":10,"outputTokens":2}}'
    printf '%s\n' '{"type":"text","text":"First progress."}'
    printf '%s' '{"type":"text","text":"Trailing'
    : >"$FAKE_DSH_CALLS/partial-ready"
    sleep "${FAKE_DSH_SLEEP:-4}"
    printf '%s\n' ' progress."}'
    printf '%s\n' '{"type":"tool_result","callId":"split-call","status":"error","result":"Denied split write"}'
    printf '%s\n' '{"type":"status","phase":"step_end","usage":{"inputTokens":20,"outputTokens":3}}'
    printf '%s\n' '{"type":"final","text":"Trailing progress."}'
    exit "${FAKE_DSH_EXIT:-0}"
    ;;
  commit)
    git commit --allow-empty -q -m fake || exit $?
    ;;
esac

cat "${FAKE_DSH_FIXTURE:-/dev/null}"
if [ -n "${FAKE_DSH_STDERR:-}" ]; then
  cat "$FAKE_DSH_STDERR" >&2
fi
exit "${FAKE_DSH_EXIT:-0}"
