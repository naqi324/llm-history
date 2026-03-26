#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SAVE_SCRIPT="$ROOT_DIR/scripts/llm-history-save.sh"
WORKER_SCRIPT="$ROOT_DIR/scripts/llm-history-worker.sh"
FIXTURES_DIR="$ROOT_DIR/tests/fixtures"
GOLDEN_DIR="$ROOT_DIR/tests/golden"
FIXED_CWD="/Users/naqi.khan/git/skills/llm-history"

# shellcheck source=tests/helpers.sh
source "$ROOT_DIR/tests/helpers.sh"

wait_for_file() {
  local path="$1"
  local attempts="${2:-80}"
  local i
  for ((i = 0; i < attempts; i += 1)); do
    if [ -f "$path" ]; then
      return 0
    fi
    sleep 0.1
  done
  fail "timed out waiting for file: $path"
}

normalize_output() {
  sed -E \
    -e 's/^date: .*/date: <DATE>/' \
    -e 's/^saved_at: .*/saved_at: <SAVED_AT>/' \
    -e 's/^session_id: .*/session_id: <SESSION_ID>/' \
    -e "s#${TEST_ROOT}#<TMP_ROOT>#g" \
    -e "s#${TEST_ROOT_REAL}#<TMP_ROOT>#g" \
    -e 's/`[0-9a-f]{7}`/`<SHA>`/g' \
    "$1"
}

setup_env() {
  local name="$1"
  TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/llm-history-${name}-XXXXXX")
  TEST_ROOT_REAL=$(python3 - <<'PY' "$TEST_ROOT"
import os
import sys
print(os.path.realpath(sys.argv[1]))
PY
)
  TEST_DIRS+=("$TEST_ROOT")
  mkdir -p "$TEST_ROOT/vault" "$TEST_ROOT/locks"

  export LLM_HISTORY_VAULT_DIR="$TEST_ROOT/vault"
  export LLM_HISTORY_LOCK_DIR="$TEST_ROOT/locks"
  export LLM_HISTORY_HOOK_LOGFILE="$TEST_ROOT/hook.log"
  export LLM_HISTORY_WORKER_LOGFILE="$TEST_ROOT/worker.log"
  export LLM_HISTORY_CLAUDE_BIN="$FIXTURES_DIR/stub-claude.sh"
  export LLM_HISTORY_TEST_CAPTURE_STDIN="$TEST_ROOT/claude-stdin.txt"
}

append_assistant_lines() {
  local path="$1"
  local count="$2"
  local i
  for ((i = 1; i <= count; i += 1)); do
    printf '%s\n' \
      "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"Extra resumed-session growth line ${i}.\"}]}}" \
      >> "$path"
  done
}

run_dispatcher() {
  local session_id="$1"
  local transcript_path="$2"
  local cwd="${3:-$FIXED_CWD}"
  local event="${4:-Stop}"
  local last_assistant_message="${5:-Need to validate fallback formatting.}"

  build_hook_input "$session_id" "$transcript_path" "$cwd" "$event" "$last_assistant_message" \
    | "$SAVE_SCRIPT"
}

compare_to_golden() {
  local actual="$1"
  local golden="$2"
  local normalized="$TEST_ROOT/normalized-$(basename "$actual")"

  normalize_output "$actual" > "$normalized"
  diff -u "$golden" "$normalized"
}

scenario_first_save_and_prompt() {
  echo "Scenario 1+7: first save creates structured output"
  setup_env first-save
  export LLM_HISTORY_TEST_CLAUDE_RESPONSE_FILE="$FIXTURES_DIR/claude-valid.txt"

  local transcript="$TEST_ROOT/transcript.jsonl"
  local session_id="11111111-1111-1111-1111-111111111111"
  local output_path="$LLM_HISTORY_VAULT_DIR/${TODAY_YYMMDD}-llm-history.md"
  local lock_path="$LLM_HISTORY_LOCK_DIR/${session_id}-save.saved"

  copy_transcript_fixture "$transcript"
  run_dispatcher "$session_id" "$transcript"
  wait_for_file "$output_path"

  assert_file_exists "$output_path"
  assert_contains "$output_path" "session_name: fixture-session"
  assert_contains "$output_path" "status: in-progress"
  assert_contains "$output_path" "  - resave"
  assert_contains "$lock_path" "saved_at_epoch="
  assert_contains "$lock_path" "transcript_lines=12"
  assert_contains "$LLM_HISTORY_TEST_CAPTURE_STDIN" "BEGIN SESSION FACTS"
  assert_contains "$LLM_HISTORY_TEST_CAPTURE_STDIN" "BEGIN REPO FACTS"
  assert_contains "$LLM_HISTORY_TEST_CAPTURE_STDIN" "BEGIN TOOL FACTS"
  assert_contains "$LLM_HISTORY_TEST_CAPTURE_STDIN" "Reviewed dispatcher guard behavior and lock-file format."
  compare_to_golden "$output_path" "$GOLDEN_DIR/worker-valid.normalized.md"

  echo "Scenario 2: same-session follow-up stays deduped"
  run_dispatcher "$session_id" "$transcript"
  sleep 1
  assert_not_exists "$LLM_HISTORY_VAULT_DIR/${TODAY_YYMMDD}-llm-history-2.md"
  assert_contains "$LLM_HISTORY_HOOK_LOGFILE" "SKIP: resave criteria not met"
}

scenario_resave_with_age_and_delta() {
  echo "Scenario 3: resumed session re-saves with age + delta"
  setup_env resave
  export LLM_HISTORY_TEST_CLAUDE_RESPONSE_FILE="$FIXTURES_DIR/claude-valid.txt"

  local transcript="$TEST_ROOT/transcript.jsonl"
  local session_id="22222222-2222-2222-2222-222222222222"
  local base_output="$LLM_HISTORY_VAULT_DIR/${TODAY_YYMMDD}-llm-history.md"
  local resave_output="$LLM_HISTORY_VAULT_DIR/${TODAY_YYMMDD}-llm-history-2.md"
  local lock_path="$LLM_HISTORY_LOCK_DIR/${session_id}-save.saved"

  copy_transcript_fixture "$transcript"
  run_dispatcher "$session_id" "$transcript"
  wait_for_file "$base_output"

  append_assistant_lines "$transcript" 5
  write_lock_file "$lock_path" "$(( $(date +%s) - 300 ))" "12"
  run_dispatcher "$session_id" "$transcript"
  wait_for_file "$resave_output"

  compare_to_golden "$resave_output" "$GOLDEN_DIR/worker-valid.normalized.md"
  assert_contains "$LLM_HISTORY_HOOK_LOGFILE" "RESAVE: resave criteria met"
}

scenario_empty_lock_bootstrap() {
  echo "Scenario 4: empty lock re-bootstraps instead of skipping forever"
  setup_env empty-lock
  export LLM_HISTORY_TEST_CLAUDE_RESPONSE_FILE="$FIXTURES_DIR/claude-valid.txt"

  local transcript="$TEST_ROOT/transcript.jsonl"
  local session_id="33333333-3333-3333-3333-333333333333"
  local base_output="$LLM_HISTORY_VAULT_DIR/${TODAY_YYMMDD}-llm-history.md"
  local lock_path="$LLM_HISTORY_LOCK_DIR/${session_id}-save.saved"

  copy_transcript_fixture "$transcript"
  printf '%s\n' \
    "---" \
    "session_id: ${session_id}" \
    "---" > "$base_output"
  : > "$lock_path"

  run_dispatcher "$session_id" "$transcript"
  sleep 1

  assert_not_exists "$LLM_HISTORY_VAULT_DIR/${TODAY_YYMMDD}-llm-history-2.md"
  assert_contains "$lock_path" "saved_at_epoch="
  assert_contains "$lock_path" "transcript_lines=12"
  assert_contains "$LLM_HISTORY_HOOK_LOGFILE" "existing vault file with invalid lock; bootstrapped lock"
}

scenario_legacy_numeric_lock() {
  echo "Scenario 5: numeric legacy lock still re-saves after migration"
  setup_env numeric-lock
  export LLM_HISTORY_TEST_CLAUDE_RESPONSE_FILE="$FIXTURES_DIR/claude-valid.txt"

  local transcript="$TEST_ROOT/transcript.jsonl"
  local session_id="44444444-4444-4444-4444-444444444444"
  local base_output="$LLM_HISTORY_VAULT_DIR/${TODAY_YYMMDD}-llm-history.md"
  local resave_output="$LLM_HISTORY_VAULT_DIR/${TODAY_YYMMDD}-llm-history-2.md"
  local lock_path="$LLM_HISTORY_LOCK_DIR/${session_id}-save.saved"

  copy_transcript_fixture "$transcript"
  printf '%s\n' \
    "---" \
    "session_id: ${session_id}" \
    "---" > "$base_output"
  printf '12\n' > "$lock_path"
  append_assistant_lines "$transcript" 5

  run_dispatcher "$session_id" "$transcript"
  wait_for_file "$resave_output"

  compare_to_golden "$resave_output" "$GOLDEN_DIR/worker-valid.normalized.md"
  assert_contains "$LLM_HISTORY_HOOK_LOGFILE" "RESAVE: legacy lock satisfied delta-only fallback"
}

scenario_worker_fallback() {
  echo "Scenario 6: malformed claude output triggers structured fallback"
  setup_env fallback
  export LLM_HISTORY_TEST_CLAUDE_RESPONSE_FILE="$FIXTURES_DIR/claude-invalid.txt"

  local transcript="$TEST_ROOT/transcript.jsonl"
  local session_id="55555555-5555-5555-5555-555555555555"
  local work_file="$TEST_ROOT/work.json"
  local output_path="$LLM_HISTORY_VAULT_DIR/${TODAY_YYMMDD}-llm-history.md"
  local fallback_cwd="$TEST_ROOT/llm-history"

  mkdir -p "$fallback_cwd"
  git init -b main "$fallback_cwd" >/dev/null
  git -C "$fallback_cwd" config user.name "Smoke Harness"
  git -C "$fallback_cwd" config user.email "smoke@example.com"
  printf '%s\n' '# smoke fallback' > "$fallback_cwd/README.md"
  git -C "$fallback_cwd" add README.md
  git -C "$fallback_cwd" commit -m "Initial commit" >/dev/null
  copy_transcript_fixture "$transcript"
  build_worker_file "$work_file" "$session_id" "$transcript" "$fallback_cwd" "$output_path" "Stop" "Need to validate fallback formatting."
  "$WORKER_SCRIPT" "$work_file"

  assert_file_exists "$output_path"
  compare_to_golden "$output_path" "$GOLDEN_DIR/worker-fallback.normalized.md"
  assert_contains "$LLM_HISTORY_WORKER_LOGFILE" "WARN: invalid structured output from claude -p"
}

scenario_first_save_and_prompt
scenario_resave_with_age_and_delta
scenario_empty_lock_bootstrap
scenario_legacy_numeric_lock
scenario_worker_fallback

echo "All smoke tests passed."
