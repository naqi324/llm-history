#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SAVE_SCRIPT="$ROOT_DIR/scripts/llm-history-save.sh"
WORKER_SCRIPT="$ROOT_DIR/scripts/llm-history-worker.sh"
FIXTURES_DIR="$ROOT_DIR/tests/fixtures"
GOLDEN_DIR="$ROOT_DIR/tests/golden"

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

init_fixed_repo() {
  local root="$1"
  mkdir -p "$root"
  git init -b main "$root" >/dev/null
  git -C "$root" config user.name "Smoke Harness"
  git -C "$root" config user.email "smoke@example.com"
  printf '%s\n' '# smoke' > "$root/README.md"
  git -C "$root" add README.md
  git -C "$root" commit -m "Initial commit" >/dev/null
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

  FIXED_CWD="$TEST_ROOT/llm-history"
  init_fixed_repo "$FIXED_CWD"

  export LLM_HISTORY_VAULT_DIR="$TEST_ROOT/vault"
  export LLM_HISTORY_LOCK_DIR="$TEST_ROOT/locks"
  export LLM_HISTORY_HOOK_LOGFILE="$TEST_ROOT/hook.log"
  export LLM_HISTORY_WORKER_LOGFILE="$TEST_ROOT/worker.log"
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

assert_forbidden_file_path_language_absent() {
  local path="$1"
  if grep -F "No concrete file paths were recorded" "$path" >/dev/null; then
    fail "forbidden 'No concrete file paths were recorded' string in $path"
  fi
}

compare_to_golden() {
  local actual="$1"
  local golden="$2"
  local normalized="$TEST_ROOT/normalized-$(basename "$actual")"

  normalize_output "$actual" > "$normalized"
  diff -u "$golden" "$normalized"
}

scenario_first_save() {
  echo "Scenario 1: first save renders a grounded deterministic handoff"
  setup_env first-save

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
  assert_contains "$output_path" "model: auto-saved (grounded deterministic)"
  assert_contains "$lock_path" "saved_at_epoch="
  assert_contains "$lock_path" "transcript_lines=12"
  assert_forbidden_file_path_language_absent "$output_path"
  compare_to_golden "$output_path" "$GOLDEN_DIR/worker-deterministic.normalized.md"
}

scenario_dedup() {
  echo "Scenario 2: same-session follow-up stays deduped"
  setup_env dedup

  local transcript="$TEST_ROOT/transcript.jsonl"
  local session_id="99999999-9999-9999-9999-999999999999"
  local output_path="$LLM_HISTORY_VAULT_DIR/${TODAY_YYMMDD}-llm-history.md"

  copy_transcript_fixture "$transcript"
  run_dispatcher "$session_id" "$transcript"
  wait_for_file "$output_path"

  run_dispatcher "$session_id" "$transcript"
  sleep 1
  assert_not_exists "$LLM_HISTORY_VAULT_DIR/${TODAY_YYMMDD}-llm-history-2.md"
  assert_contains "$LLM_HISTORY_HOOK_LOGFILE" "SKIP: resave criteria not met"
}

scenario_resave_with_age_and_delta() {
  echo "Scenario 3: resumed session re-saves with age + delta"
  setup_env resave

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

  compare_to_golden "$resave_output" "$GOLDEN_DIR/worker-deterministic-resave.normalized.md"
  assert_contains "$LLM_HISTORY_HOOK_LOGFILE" "RESAVE: resave criteria met"
}

scenario_empty_lock_bootstrap() {
  echo "Scenario 4: empty lock re-bootstraps instead of skipping forever"
  setup_env empty-lock

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

  compare_to_golden "$resave_output" "$GOLDEN_DIR/worker-deterministic-resave.normalized.md"
  assert_contains "$LLM_HISTORY_HOOK_LOGFILE" "RESAVE: legacy lock satisfied delta-only fallback"
}

scenario_session_end_mode() {
  echo "Scenario 6: session-end-sync render mode produces identical deterministic output"
  setup_env session-end

  local transcript="$TEST_ROOT/transcript.jsonl"
  local session_id="55555555-5555-5555-5555-555555555555"
  local work_file="$TEST_ROOT/work.json"
  local output_path="$LLM_HISTORY_VAULT_DIR/${TODAY_YYMMDD}-llm-history.md"

  copy_transcript_fixture "$transcript"
  build_worker_file "$work_file" "$session_id" "$transcript" "$FIXED_CWD" "$output_path"
  LLM_HISTORY_RENDER_MODE=session-end-sync "$WORKER_SCRIPT" "$work_file"

  assert_file_exists "$output_path"
  assert_contains "$output_path" "model: auto-saved (grounded deterministic)"
  assert_contains "$LLM_HISTORY_WORKER_LOGFILE" "render_mode=session-end-sync"
  assert_forbidden_file_path_language_absent "$output_path"
  compare_to_golden "$output_path" "$GOLDEN_DIR/worker-deterministic.normalized.md"
}

scenario_title_sanitation() {
  echo "Scenario 7: pasted skill content does not land in title/headline"
  setup_env title-sanitation

  local transcript="$TEST_ROOT/transcript-title-corruption.jsonl"
  local session_id="77777777-7777-7777-7777-777777777777"
  local work_file="$TEST_ROOT/work.json"
  local output_path="$LLM_HISTORY_VAULT_DIR/${TODAY_YYMMDD}-llm-history.md"

  cp "$FIXTURES_DIR/transcript-title-corruption.jsonl" "$transcript"
  build_worker_file "$work_file" "$session_id" "$transcript" "$FIXED_CWD" "$output_path"
  "$WORKER_SCRIPT" "$work_file"

  local title_line
  title_line=$(grep '^title:' "$output_path")
  if grep -F '/Users/naqi.khan/.claude/skills/git-ops' "$output_path" >/dev/null; then
    if printf '%s\n' "$title_line" | grep -F '/Users/naqi.khan/.claude/skills/git-ops' >/dev/null; then
      fail "title leaked skill path: $title_line"
    fi
  fi
  if printf '%s\n' "$title_line" | grep -E "^title: '?#" >/dev/null; then
    fail "title starts with markdown header: $title_line"
  fi
  local title_value
  title_value=$(printf '%s' "$title_line" | sed -E "s/^title: '?(.*)'?$/\1/" | sed "s/'$//")
  local title_len=${#title_value}
  if [ "$title_len" -gt 80 ]; then
    fail "title exceeds 80 chars ($title_len): $title_line"
  fi
}

scenario_instruction_dump_elided() {
  echo "Scenario 8: instruction-dump assistant text is elided before it enters the summary"
  setup_env instruction-dump

  local transcript="$TEST_ROOT/transcript-instruction-dump.jsonl"
  local session_id="88888888-8888-8888-8888-888888888888"
  local work_file="$TEST_ROOT/work.json"
  local bundle_file="$TEST_ROOT/bundle.json"
  local output_path="$LLM_HISTORY_VAULT_DIR/${TODAY_YYMMDD}-llm-history.md"

  cp "$FIXTURES_DIR/transcript-instruction-dump.jsonl" "$transcript"
  build_worker_file "$work_file" "$session_id" "$transcript" "$FIXED_CWD" "$output_path"
  python3 "$ROOT_DIR/scripts/llm-history-context.py" "$work_file" > "$bundle_file"
  "$WORKER_SCRIPT" "$work_file"

  assert_file_exists "$output_path"
  # None of the skill-paste's distinctive markers may appear in the rendered handoff.
  if grep -E "SKILL\.md|YAML frontmatter|Supported Flags|Skill Contract|~/\.claude/skills/git-ops" "$output_path" >/dev/null; then
    fail "instruction-dump content leaked into rendered handoff: $output_path"
  fi
  # The bundle must record the elision so downstream consumers can tell something was dropped.
  assert_contains "$bundle_file" "instruction-dump elided"
}

scenario_plan_mode_surface() {
  echo "Scenario 9: plan-mode sessions surface the plan file path in the handoff"
  setup_env plan-mode

  local transcript="$TEST_ROOT/transcript-plan-mode.jsonl"
  local session_id="aaaaaaa9-0000-0000-0000-000000000009"
  local work_file="$TEST_ROOT/work.json"
  local bundle_file="$TEST_ROOT/bundle.json"
  local output_path="$LLM_HISTORY_VAULT_DIR/${TODAY_YYMMDD}-llm-history.md"

  cp "$FIXTURES_DIR/transcript-plan-mode.jsonl" "$transcript"
  build_worker_file "$work_file" "$session_id" "$transcript" "$FIXED_CWD" "$output_path"
  python3 "$ROOT_DIR/scripts/llm-history-context.py" "$work_file" > "$bundle_file"
  "$WORKER_SCRIPT" "$work_file"

  assert_jq '.derived.plan_state.in_plan_mode == true' "$bundle_file"
  assert_jq '.derived.plan_state.plan_file == "/Users/naqi.khan/.claude/plans/refactor-thing.md"' "$bundle_file"
  assert_jq '.derived.plan_state.plan_exists == true' "$bundle_file"
  assert_jq '.derived.plan_state.plan_finalized == false' "$bundle_file"
  assert_contains "$output_path" "Paused in plan mode"
  assert_contains "$output_path" "/Users/naqi.khan/.claude/plans/refactor-thing.md"
  # Plan-mode is the highest-priority next-step case: step 1 must point at the plan file.
  assert_jq '.derived.next_steps[0] | test("Open the plan at `/Users/naqi.khan/.claude/plans/refactor-thing.md`")' "$bundle_file"
}

scenario_edit_then_error() {
  echo "Scenario 10: edit followed by failing command yields a reproduction step 1"
  setup_env edit-then-error

  local transcript="$TEST_ROOT/transcript-edit-then-error.jsonl"
  local session_id="bbbbbbb0-0000-0000-0000-0000000000b0"
  local work_file="$TEST_ROOT/work.json"
  local bundle_file="$TEST_ROOT/bundle.json"
  local output_path="$LLM_HISTORY_VAULT_DIR/${TODAY_YYMMDD}-llm-history.md"

  cp "$FIXTURES_DIR/transcript-edit-then-error.jsonl" "$transcript"
  build_worker_file "$work_file" "$session_id" "$transcript" "$FIXED_CWD" "$output_path"
  python3 "$ROOT_DIR/scripts/llm-history-context.py" "$work_file" > "$bundle_file"
  "$WORKER_SCRIPT" "$work_file"

  # Step 1 names the failing pytest command and the edited file.
  assert_jq '.derived.next_steps[0] | test("pytest tests/test_auth\\.py::test_login")' "$bundle_file"
  assert_jq '.derived.next_steps[0] | test("src/auth\\.py")' "$bundle_file"
}

scenario_todo_ledger() {
  echo "Scenario 11: TodoWrite state renders a classified task ledger"
  setup_env todo-ledger

  local transcript="$TEST_ROOT/transcript-todo-ledger.jsonl"
  local session_id="ddddddd0-0000-0000-0000-0000000000d0"
  local work_file="$TEST_ROOT/work.json"
  local bundle_file="$TEST_ROOT/bundle.json"
  local output_path="$LLM_HISTORY_VAULT_DIR/${TODAY_YYMMDD}-llm-history.md"

  cp "$FIXTURES_DIR/transcript-todo-ledger.jsonl" "$transcript"
  build_worker_file "$work_file" "$session_id" "$transcript" "$FIXED_CWD" "$output_path"
  python3 "$ROOT_DIR/scripts/llm-history-context.py" "$work_file" > "$bundle_file"
  "$WORKER_SCRIPT" "$work_file"

  assert_jq '.tools.todo_items | length == 3' "$bundle_file"
  assert_contains "$output_path" "### DONE"
  assert_contains "$output_path" "Define resume packet sections"
  assert_contains "$output_path" "### PARTIALLY DONE"
  assert_contains "$output_path" "Wire renderer to resume_packet"
  assert_contains "$output_path" "### NOT DONE"
  assert_contains "$output_path" "Regenerate deterministic goldens"
}

scenario_completed_clean_status() {
  echo "Scenario 12: clean completed sessions surface completed status and do-not-redo guidance"
  setup_env completed-clean

  local transcript="$TEST_ROOT/transcript-completed-clean.jsonl"
  local session_id="eeeeeee0-0000-0000-0000-0000000000e0"
  local work_file="$TEST_ROOT/work.json"
  local output_path="$LLM_HISTORY_VAULT_DIR/${TODAY_YYMMDD}-llm-history.md"

  cp "$FIXTURES_DIR/transcript-completed-clean.jsonl" "$transcript"
  build_worker_file "$work_file" "$session_id" "$transcript" "$FIXED_CWD" "$output_path"
  "$WORKER_SCRIPT" "$work_file"

  assert_contains "$output_path" "status: completed"
  assert_contains "$output_path" "Committed docs cleanup and pushed to origin/main."
  assert_contains "$output_path" "Do not redo completed work"
}

scenario_render_failure_emergency() {
  echo "Scenario 14: renderer failure writes an emergency dump instead of losing the session"
  setup_env emergency

  local transcript="$TEST_ROOT/transcript.jsonl"
  local session_id="ffffffff-0000-0000-0000-00000000abcd"
  local work_file="$TEST_ROOT/work.json"
  local output_path="$LLM_HISTORY_VAULT_DIR/${TODAY_YYMMDD}-llm-history.md"

  copy_transcript_fixture "$transcript"
  build_worker_file "$work_file" "$session_id" "$transcript" "$FIXED_CWD" "$output_path"

  # Substitute a helper that always exits 1 before producing any output. The
  # worker's failure handler must still land an emergency file and set the
  # result file accordingly.
  local broken_helper="$TEST_ROOT/broken-context.py"
  cat > "$broken_helper" <<'PY'
#!/usr/bin/env python3
import sys
sys.stderr.write("simulated context.py failure\n")
sys.exit(99)
PY
  chmod +x "$broken_helper"

  local result_file="$TEST_ROOT/result.kv"
  rm -f "$result_file"

  local emergency_path="$LLM_HISTORY_VAULT_DIR/${TODAY_YYMMDD}-llm-history-EMERGENCY-${session_id:0:8}.md"

  if LLM_HISTORY_CONTEXT_HELPER="$broken_helper" \
     LLM_HISTORY_RESULT_FILE="$result_file" \
     LLM_HISTORY_RENDER_MODE=session-end-sync \
     "$WORKER_SCRIPT" "$work_file"; then
    fail "worker should exit non-zero when context helper fails"
  fi

  assert_file_exists "$emergency_path"
  assert_contains "$emergency_path" "Emergency Context Dump"
  assert_contains "$emergency_path" "trigger: session-end-emergency"
  assert_contains "$emergency_path" "failed_stage: context-bundle"
  assert_contains "$result_file" "result=error"
  assert_contains "$result_file" "detail=render-failed-context-bundle"
  assert_contains "$result_file" "file_path=$emergency_path"
  assert_contains "$LLM_HISTORY_WORKER_LOGFILE" "FAIL session="
  # No normal handoff file should exist, since we refused to write one.
  assert_not_exists "$output_path"
}

scenario_generic_step_rejected() {
  echo "Scenario 13: denied generic step never becomes step 1"
  setup_env generic-rejected

  local transcript="$TEST_ROOT/transcript.jsonl"
  local session_id="ccccccc0-0000-0000-0000-0000000000c0"
  local work_file="$TEST_ROOT/work.json"
  local bundle_file="$TEST_ROOT/bundle.json"
  local output_path="$LLM_HISTORY_VAULT_DIR/${TODAY_YYMMDD}-llm-history.md"

  # Base fixture has no tool calls and a specific user ask; expect priority 4
  # (imperative user ask) -- not "Run git status" or any denied phrase.
  copy_transcript_fixture "$transcript"
  build_worker_file "$work_file" "$session_id" "$transcript" "$FIXED_CWD" "$output_path"
  python3 "$ROOT_DIR/scripts/llm-history-context.py" "$work_file" > "$bundle_file"
  "$WORKER_SCRIPT" "$work_file"

  assert_jq '.derived.next_steps[0] | test("^Run `git status"; "i") | not' "$bundle_file"
  assert_jq '.derived.next_steps[0] | test("^Continue\\.?$"; "i") | not' "$bundle_file"
}

scenario_first_save
scenario_dedup
scenario_resave_with_age_and_delta
scenario_empty_lock_bootstrap
scenario_legacy_numeric_lock
scenario_session_end_mode
scenario_title_sanitation
scenario_instruction_dump_elided
scenario_plan_mode_surface
scenario_edit_then_error
scenario_todo_ledger
scenario_completed_clean_status
scenario_generic_step_rejected
scenario_render_failure_emergency

echo "All smoke tests passed."
