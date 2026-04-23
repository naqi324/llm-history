#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ORCHESTRATOR="$ROOT_DIR/scripts/exit-orchestrator.sh"
AUDIT_SCRIPT="$ROOT_DIR/scripts/exit-audit.sh"
REAL_GIT_SCRIPT="/Users/naqi.khan/git/system/CLAUDE-md/.claude/hooks/auto-git-commit.sh"
FIXTURES_DIR="$ROOT_DIR/tests/fixtures"

# shellcheck source=tests/helpers.sh
source "$ROOT_DIR/tests/helpers.sh"

assert_claude_not_called() {
  assert_not_exists "$TEST_ROOT/logs/claude-invoked.log"
}

assert_nontrivial_history_output() {
  local path="$1"
  assert_file_exists "$path"
  assert_contains "$path" "## Executive Summary"
  assert_contains "$path" "## Working State"
  assert_contains "$path" "## Files Changed"
  assert_contains "$path" "## Concrete Next Steps"
}

setup_env() {
  local name="$1"
  TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/exit-orchestrator-${name}-XXXXXX")
  TEST_DIRS+=("$TEST_ROOT")
  mkdir -p "$TEST_ROOT/vault" "$TEST_ROOT/locks" "$TEST_ROOT/logs" "$TEST_ROOT/bin"

  export CLAUDE_EXIT_LOGFILE="$TEST_ROOT/logs/exit.log"
  export AUTO_GIT_LOGFILE="$TEST_ROOT/logs/auto-git.log"
  export LLM_HISTORY_VAULT_DIR="$TEST_ROOT/vault"
  export LLM_HISTORY_LOCK_DIR="$TEST_ROOT/locks"
  export LLM_HISTORY_HOOK_LOGFILE="$TEST_ROOT/logs/history.log"
  export LLM_HISTORY_WORKER_LOGFILE="$TEST_ROOT/logs/worker.log"
  export GIT_AUTHOR_NAME="Exit Smoke"
  export GIT_AUTHOR_EMAIL="exit-smoke@example.com"
  export GIT_COMMITTER_NAME="Exit Smoke"
  export GIT_COMMITTER_EMAIL="exit-smoke@example.com"

  cat > "$TEST_ROOT/bin/gitleaks" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$TEST_ROOT/bin/gitleaks"

  cat > "$TEST_ROOT/bin/claude" <<EOF
#!/usr/bin/env bash
# If anything tries to invoke \`claude\`, record it. The deterministic worker
# must never call the real binary.
echo "invoked \$*" >> "$TEST_ROOT/logs/claude-invoked.log"
exit 91
EOF
  chmod +x "$TEST_ROOT/bin/claude"

  export PATH="$TEST_ROOT/bin:$PATH"

  unset CLAUDE_EXIT_GIT_SCRIPT
  unset CLAUDE_EXIT_HISTORY_SCRIPT
}

write_trivial_transcript() {
  local target="$1"
  printf '%s\n' '{}' '{}' '{}' '{}' '{}' '{}' '{}' '{}' > "$target"
}

init_repo_with_remote() {
  local repo="$1"
  local remote="$2"

  mkdir -p "$repo" "$remote"
  git init --bare "$remote" >/dev/null
  git init -b main "$repo" >/dev/null
  git -C "$repo" config user.name "Exit Smoke"
  git -C "$repo" config user.email "exit-smoke@example.com"
  echo "# demo" > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -m "Initial commit" >/dev/null
  git -C "$repo" remote add origin "$remote"
  git -C "$repo" push -u origin main >/dev/null 2>&1
}

run_orchestrator() {
  local session_id="$1"
  local transcript_path="$2"
  local cwd="$3"

  build_hook_input "$session_id" "$transcript_path" "$cwd" "SessionEnd" "Exit orchestrator smoke test." \
    | "$ORCHESTRATOR"
}

assert_phase_order() {
  local path="$1"
  local phases

  phases=$(jq -r 'select(.phase == "git" or .phase == "history") | .phase' "$path")
  [ "$phases" = $'git\nhistory' ] || fail "unexpected phase order in $path: ${phases:-<empty>}"
}

scenario_dirty_repo() {
  echo "Scenario 1: dirty repo with origin on main commits first, then writes history"
  setup_env dirty
  export CLAUDE_EXIT_GIT_SCRIPT="$REAL_GIT_SCRIPT"

  local repo="$TEST_ROOT/demo-repo"
  local remote="$TEST_ROOT/demo-remote.git"
  local transcript="$TEST_ROOT/transcript.jsonl"
  local session_id="90000000-0000-0000-0000-000000000001"
  local output_path="$LLM_HISTORY_VAULT_DIR/${TODAY_YYMMDD}-demo-repo.md"

  init_repo_with_remote "$repo" "$remote"
  copy_transcript_fixture "$transcript"
  echo "change" >> "$repo/README.md"

  run_orchestrator "$session_id" "$transcript" "$repo"

  assert_nontrivial_history_output "$output_path"
  [ -z "$(git -C "$repo" status --short)" ] || fail "repo should be clean after orchestrator"
  assert_phase_order "$CLAUDE_EXIT_LOGFILE"
  assert_jq 'select(.phase == "git" and .result == "success" and .detail == "push-ok")' "$CLAUDE_EXIT_LOGFILE"
  assert_jq 'select(.phase == "history" and .result == "success" and .history_render_mode == "session-end-sync")' "$CLAUDE_EXIT_LOGFILE"
  assert_jq 'select(.phase == "pipeline" and .state == "done" and .overall == "success")' "$CLAUDE_EXIT_LOGFILE"
  assert_claude_not_called
}

scenario_clean_repo() {
  echo "Scenario 2: clean repo skips git work but still saves history"
  setup_env clean
  export CLAUDE_EXIT_GIT_SCRIPT="$REAL_GIT_SCRIPT"

  local repo="$TEST_ROOT/clean-repo"
  local remote="$TEST_ROOT/clean-remote.git"
  local transcript="$TEST_ROOT/transcript.jsonl"
  local session_id="90000000-0000-0000-0000-000000000002"
  local output_path="$LLM_HISTORY_VAULT_DIR/${TODAY_YYMMDD}-clean-repo.md"

  init_repo_with_remote "$repo" "$remote"
  copy_transcript_fixture "$transcript"

  run_orchestrator "$session_id" "$transcript" "$repo"

  assert_nontrivial_history_output "$output_path"
  assert_phase_order "$CLAUDE_EXIT_LOGFILE"
  assert_jq 'select(.phase == "git" and .result == "skip-clean-repo")' "$CLAUDE_EXIT_LOGFILE"
  assert_jq 'select(.phase == "history" and .result == "success" and .history_render_mode == "session-end-sync")' "$CLAUDE_EXIT_LOGFILE"
  assert_claude_not_called
}

scenario_non_git_directory() {
  echo "Scenario 3: non-git directory initializes repo and still writes history"
  setup_env nongit
  export CLAUDE_EXIT_GIT_SCRIPT="$REAL_GIT_SCRIPT"

  local worktree="$TEST_ROOT/plain-dir"
  local transcript="$TEST_ROOT/transcript.jsonl"
  local session_id="90000000-0000-0000-0000-000000000003"
  local output_path="$LLM_HISTORY_VAULT_DIR/${TODAY_YYMMDD}-plain-dir.md"

  mkdir -p "$worktree"
  copy_transcript_fixture "$transcript"

  run_orchestrator "$session_id" "$transcript" "$worktree"

  assert_nontrivial_history_output "$output_path"
  assert_file_exists "$worktree/.gitignore"
  assert_jq 'select(.phase == "git" and .result == "success" and .detail == "initialized-repo")' "$CLAUDE_EXIT_LOGFILE"
  assert_jq 'select(.phase == "history" and .result == "success" and .history_render_mode == "session-end-sync")' "$CLAUDE_EXIT_LOGFILE"
  assert_claude_not_called
}

scenario_trivial_session() {
  echo "Scenario 4: trivial transcript skips history without invoking claude -p"
  setup_env trivial
  export CLAUDE_EXIT_GIT_SCRIPT="$REAL_GIT_SCRIPT"

  local repo="$TEST_ROOT/trivial-repo"
  local remote="$TEST_ROOT/trivial-remote.git"
  local transcript="$TEST_ROOT/trivial-transcript.jsonl"
  local session_id="90000000-0000-0000-0000-000000000004"

  init_repo_with_remote "$repo" "$remote"
  write_trivial_transcript "$transcript"

  run_orchestrator "$session_id" "$transcript" "$repo"

  assert_phase_order "$CLAUDE_EXIT_LOGFILE"
  assert_jq 'select(.phase == "history" and .result == "skip-trivial")' "$CLAUDE_EXIT_LOGFILE"
  assert_jq 'select(.phase == "pipeline" and .state == "done" and .overall == "success")' "$CLAUDE_EXIT_LOGFILE"
  assert_claude_not_called
}

scenario_missing_transcript() {
  echo "Scenario 5: missing transcript is logged explicitly and exit still completes"
  setup_env missing
  export CLAUDE_EXIT_GIT_SCRIPT="$REAL_GIT_SCRIPT"

  local repo="$TEST_ROOT/missing-repo"
  local remote="$TEST_ROOT/missing-remote.git"
  local transcript="$TEST_ROOT/does-not-exist.jsonl"
  local session_id="90000000-0000-0000-0000-000000000005"

  init_repo_with_remote "$repo" "$remote"

  run_orchestrator "$session_id" "$transcript" "$repo"

  assert_phase_order "$CLAUDE_EXIT_LOGFILE"
  assert_jq 'select(.phase == "history" and .result == "skip-missing-transcript")' "$CLAUDE_EXIT_LOGFILE"
  assert_jq 'select(.phase == "pipeline" and .state == "done" and .overall == "success")' "$CLAUDE_EXIT_LOGFILE"
  assert_claude_not_called
}

scenario_history_dedup_skip() {
  echo "Scenario 6: second exit logs explicit history dedup skip"
  setup_env dedup
  export CLAUDE_EXIT_GIT_SCRIPT="$REAL_GIT_SCRIPT"

  local repo="$TEST_ROOT/dedup-repo"
  local remote="$TEST_ROOT/dedup-remote.git"
  local transcript="$TEST_ROOT/transcript.jsonl"
  local session_id="90000000-0000-0000-0000-000000000006"
  local output_path="$LLM_HISTORY_VAULT_DIR/${TODAY_YYMMDD}-dedup-repo.md"
  local second_output="$LLM_HISTORY_VAULT_DIR/${TODAY_YYMMDD}-dedup-repo-2.md"

  init_repo_with_remote "$repo" "$remote"
  copy_transcript_fixture "$transcript"
  echo "change" >> "$repo/README.md"

  run_orchestrator "$session_id" "$transcript" "$repo"
  run_orchestrator "$session_id" "$transcript" "$repo"

  assert_file_exists "$output_path"
  [ ! -f "$second_output" ] || fail "did not expect dedup re-save output: $second_output"
  assert_jq 'select(.phase == "history" and .result == "skip-dedup")' "$CLAUDE_EXIT_LOGFILE"
  assert_jq 'select(.phase == "pipeline" and .state == "done" and .history_result == "skip-dedup")' "$CLAUDE_EXIT_LOGFILE"
  assert_claude_not_called
}

scenario_git_failure_history_still_runs() {
  echo "Scenario 7: git failure is logged and history still runs"
  setup_env git-failure
  export CLAUDE_EXIT_GIT_SCRIPT="$FIXTURES_DIR/git-fail-hook.sh"

  local worktree="$TEST_ROOT/failing-dir"
  local transcript="$TEST_ROOT/transcript.jsonl"
  local session_id="90000000-0000-0000-0000-000000000007"
  local output_path="$LLM_HISTORY_VAULT_DIR/${TODAY_YYMMDD}-failing-dir.md"

  mkdir -p "$worktree"
  copy_transcript_fixture "$transcript"

  if run_orchestrator "$session_id" "$transcript" "$worktree"; then
    fail "orchestrator should return non-zero when git phase fails"
  fi

  assert_nontrivial_history_output "$output_path"
  assert_phase_order "$CLAUDE_EXIT_LOGFILE"
  assert_jq 'select(.phase == "git" and .result == "error" and .detail == "synthetic-failure")' "$CLAUDE_EXIT_LOGFILE"
  assert_jq 'select(.phase == "history" and .result == "success" and .history_render_mode == "session-end-sync")' "$CLAUDE_EXIT_LOGFILE"
  assert_jq 'select(.phase == "pipeline" and .state == "done" and .overall == "error")' "$CLAUDE_EXIT_LOGFILE"
  assert_claude_not_called
}

scenario_exit_audit() {
  echo "Scenario 8: exit-audit reports exit-safe runs and flags incomplete ones"
  setup_env audit
  export CLAUDE_EXIT_GIT_SCRIPT="$REAL_GIT_SCRIPT"

  local repo="$TEST_ROOT/audit-repo"
  local remote="$TEST_ROOT/audit-remote.git"
  local transcript="$TEST_ROOT/transcript.jsonl"
  local session_id="90000000-0000-0000-0000-000000000008"
  local audit_output="$TEST_ROOT/audit.txt"

  init_repo_with_remote "$repo" "$remote"
  copy_transcript_fixture "$transcript"

  run_orchestrator "$session_id" "$transcript" "$repo"

  jq -cn \
    --arg timestamp "$(date -Iseconds)" \
    --arg session_id "90000000-0000-0000-0000-000000000009" \
    --arg cwd "$repo" \
    '{timestamp:$timestamp, session_id:$session_id, cwd:$cwd, hook_event:"SessionEnd", phase:"pipeline", state:"start"}' >> "$CLAUDE_EXIT_LOGFILE"

  CLAUDE_EXIT_LOGFILE="$CLAUDE_EXIT_LOGFILE" "$AUDIT_SCRIPT" 5 > "$audit_output"

  assert_contains "$audit_output" $'TIMESTAMP\tSESSION\tGIT\tHISTORY\tOVERALL\tEXIT_SAFE\tCWD'
  assert_contains "$audit_output" "$session_id"
  assert_contains "$audit_output" "safe"
  assert_contains "$audit_output" "missing-history-or-done"
}

scenario_dirty_repo
scenario_clean_repo
scenario_non_git_directory
scenario_trivial_session
scenario_missing_transcript
scenario_history_dedup_skip
scenario_git_failure_history_still_runs
scenario_exit_audit

echo "exit-orchestrator smoke tests passed"
