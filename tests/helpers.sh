#!/usr/bin/env bash
# Shared test helpers — sourced by all test harnesses.

TEST_DIRS=()

cleanup() {
  local dir
  for dir in "${TEST_DIRS[@]:-}"; do
    rm -rf "$dir"
  done
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file_exists() {
  [ -f "$1" ] || fail "expected file to exist: $1"
}

assert_not_exists() {
  [ ! -e "$1" ] || fail "expected path to be absent: $1"
}

assert_contains() {
  local path="$1"
  local needle="$2"
  grep -F "$needle" "$path" >/dev/null || fail "expected '$needle' in $path"
}

assert_jq() {
  local filter="$1"
  local path="$2"
  jq -e "$filter" "$path" >/dev/null || fail "jq assertion failed: $filter on $path"
}

copy_transcript_fixture() {
  local target="$1"
  cp "${FIXTURES_DIR:?FIXTURES_DIR must be set}/transcript-base.jsonl" "$target"
}

# Date constants used by test helpers and scenarios
TODAY_YYMMDD=$(date +%y%m%d)
TODAY_ISO=$(date +%Y-%m-%d)

write_lock_file() {
  local path="$1"
  local saved_at_epoch="$2"
  local transcript_lines="$3"
  printf 'saved_at_epoch=%s\ntranscript_lines=%s\n' \
    "$saved_at_epoch" "$transcript_lines" > "$path"
}

build_hook_input() {
  local session_id="$1"
  local transcript_path="$2"
  local cwd="$3"
  local event="${4:-Stop}"
  local last_assistant_message="${5:-Session test.}"

  jq -n \
    --arg session_id "$session_id" \
    --arg transcript_path "$transcript_path" \
    --arg cwd "$cwd" \
    --arg hook_event_name "$event" \
    --arg last_assistant_message "$last_assistant_message" \
    '{
      session_id: $session_id,
      transcript_path: $transcript_path,
      cwd: $cwd,
      hook_event_name: $hook_event_name,
      stop_hook_active: false,
      last_assistant_message: $last_assistant_message
    }'
}

build_worker_file() {
  local work_file="$1"
  local session_id="$2"
  local transcript_path="$3"
  local cwd="$4"
  local output_path="$5"
  local event="${6:-Stop}"
  local last_assistant_message="${7:-Session test.}"
  local hook_input_json

  hook_input_json=$(build_hook_input "$session_id" "$transcript_path" "$cwd" "$event" "$last_assistant_message")

  jq -n \
    --arg transcript_path "$transcript_path" \
    --arg cwd "$cwd" \
    --arg hook_event "$event" \
    --arg session_id "$session_id" \
    --arg file_path "$output_path" \
    --arg base_name "${TODAY_YYMMDD}-$(basename "$cwd")" \
    --arg date_iso "$TODAY_ISO" \
    --arg saved_at "$(date -Iseconds)" \
    --arg hook_input_json "$hook_input_json" \
    '{
      transcript_path: $transcript_path,
      cwd: $cwd,
      hook_event: $hook_event,
      session_id: $session_id,
      file_path: $file_path,
      base_name: $base_name,
      date_iso: $date_iso,
      saved_at: $saved_at,
      hook_input_json: $hook_input_json
    }' > "$work_file"
}
