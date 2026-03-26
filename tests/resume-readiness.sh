#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKER_SCRIPT="$ROOT_DIR/scripts/llm-history-worker.sh"
CONTEXT_SCRIPT="$ROOT_DIR/scripts/llm-history-context.py"
CHECKER_SCRIPT="$ROOT_DIR/tests/check_resume_readiness.py"
FIXTURES_DIR="$ROOT_DIR/tests/fixtures"
REPORT_DIR="$ROOT_DIR/tests/logs"
SCENARIO_REPORTS=()

# shellcheck source=tests/helpers.sh
source "$ROOT_DIR/tests/helpers.sh"

setup_env() {
  local name="$1"
  TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/llm-history-quality-${name}-XXXXXX")
  TEST_DIRS+=("$TEST_ROOT")
  mkdir -p "$TEST_ROOT/vault" "$TEST_ROOT/locks"

  export LLM_HISTORY_VAULT_DIR="$TEST_ROOT/vault"
  export LLM_HISTORY_LOCK_DIR="$TEST_ROOT/locks"
  export LLM_HISTORY_HOOK_LOGFILE="$TEST_ROOT/hook.log"
  export LLM_HISTORY_WORKER_LOGFILE="$TEST_ROOT/worker.log"
  export LLM_HISTORY_CLAUDE_BIN="$FIXTURES_DIR/stub-claude.sh"
  export LLM_HISTORY_TEST_CAPTURE_STDIN="$TEST_ROOT/claude-stdin.txt"
}

seed_project_tree() {
  local root="$1"

  mkdir -p "$root/scripts" "$root/references" "$root/notes"
  printf '%s\n' '# worker' > "$root/scripts/llm-history-worker.sh"
  printf '%s\n' '# prompt' > "$root/references/prompt.md"
  printf '%s\n' '# orchestrator' > "$root/scripts/exit-orchestrator.sh"
  printf '%s\n' '# audit' > "$root/scripts/exit-audit.sh"
  printf '%s\n' '# research notes' > "$root/notes/research.md"
  printf '%s\n' '# readme' > "$root/README.md"
}

init_git_repo() {
  local root="$1"
  seed_project_tree "$root"
  git init -b main "$root" >/dev/null
  git -C "$root" config user.name "Quality Harness"
  git -C "$root" config user.email "quality-harness@example.com"
  git -C "$root" add .
  git -C "$root" commit -m "Initial commit" >/dev/null
}

copy_quality_transcript() {
  local fixture_name="$1"
  local target="$2"
  local project_root="$3"
  sed "s|__PROJECT_ROOT__|$project_root|g" \
    "$FIXTURES_DIR/quality/${fixture_name}" > "$target"
}

run_and_score() {
  local scenario="$1"
  local fixture_transcript="$2"
  local response_fixture="$3"
  local project_root="$4"
  local output_path="$5"
  local session_id="$6"
  local expected_log_snippet="${7:-}"
  local bundle_path="$TEST_ROOT/${scenario}-bundle.json"
  local work_file="$TEST_ROOT/${scenario}-work.json"
  local report_path="$TEST_ROOT/${scenario}-report.json"

  export LLM_HISTORY_TEST_CLAUDE_RESPONSE_FILE="$FIXTURES_DIR/${response_fixture}"
  build_worker_file "$work_file" "$session_id" "$fixture_transcript" "$project_root" "$output_path"
  python3 "$CONTEXT_SCRIPT" "$work_file" > "$bundle_path"
  "$WORKER_SCRIPT" "$work_file"

  assert_file_exists "$output_path"
  if [ -n "$expected_log_snippet" ]; then
    assert_contains "$LLM_HISTORY_WORKER_LOGFILE" "$expected_log_snippet"
  fi

  python3 "$CHECKER_SCRIPT" "$output_path" "$bundle_path" "$scenario" > "$report_path" \
    || fail "resume-readiness evaluation failed for $scenario"

  SCENARIO_REPORTS+=("$report_path")
}

scenario_code_heavy_good() {
  echo "Scenario 1: code-heavy dirty repo accepts grounded output"
  setup_env code-heavy
  local project_root="$TEST_ROOT/code-heavy-repo"
  local transcript="$TEST_ROOT/transcript-code-heavy.jsonl"
  local output_path="$LLM_HISTORY_VAULT_DIR/${TODAY_YYMMDD}-code-heavy-repo.md"

  init_git_repo "$project_root"
  printf '%s\n' '# worker updated' >> "$project_root/scripts/llm-history-worker.sh"
  printf '%s\n' '# prompt updated' >> "$project_root/references/prompt.md"
  copy_quality_transcript "transcript-code-heavy.jsonl" "$transcript" "$project_root"

  local work_file="$TEST_ROOT/context-work.json"
  build_worker_file "$work_file" "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" "$transcript" "$project_root" "$output_path"
  python3 "$CONTEXT_SCRIPT" "$work_file" > "$TEST_ROOT/code-heavy-bundle.json"
  assert_jq '.repo.is_git == true' "$TEST_ROOT/code-heavy-bundle.json"
  assert_jq '.tools.edit_files | index("scripts/llm-history-worker.sh") != null' "$TEST_ROOT/code-heavy-bundle.json"
  assert_jq '.tools.snapshot_files | index("scripts/llm-history-worker.sh") != null' "$TEST_ROOT/code-heavy-bundle.json"
  assert_jq '.tools.likely_checks | index("bash -n scripts/llm-history-worker.sh") != null' "$TEST_ROOT/code-heavy-bundle.json"

  run_and_score "code-heavy-good" "$transcript" "claude-grounded-code.txt" "$project_root" "$output_path" \
    "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"

  assert_contains "$LLM_HISTORY_TEST_CAPTURE_STDIN" "BEGIN SESSION FACTS"
  assert_contains "$LLM_HISTORY_TEST_CAPTURE_STDIN" "BEGIN REPO FACTS"
  assert_contains "$LLM_HISTORY_TEST_CAPTURE_STDIN" "BEGIN TOOL FACTS"
  assert_contains "$LLM_HISTORY_TEST_CAPTURE_STDIN" "bash -n scripts/llm-history-worker.sh"
}

scenario_research_clean_missing_sections() {
  echo "Scenario 2: clean research session rejects missing sections and uses fallback"
  setup_env research-clean
  local project_root="$TEST_ROOT/research-clean-repo"
  local transcript="$TEST_ROOT/transcript-research-clean.jsonl"
  local output_path="$LLM_HISTORY_VAULT_DIR/${TODAY_YYMMDD}-research-clean-repo.md"
  local bundle_path="$TEST_ROOT/research-clean-bundle.json"
  local work_file="$TEST_ROOT/context-work.json"

  init_git_repo "$project_root"
  copy_quality_transcript "transcript-research-clean.jsonl" "$transcript" "$project_root"
  build_worker_file "$work_file" "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" "$transcript" "$project_root" "$output_path"
  python3 "$CONTEXT_SCRIPT" "$work_file" > "$bundle_path"
  assert_jq '.repo.status_clean == true' "$bundle_path"

  run_and_score "research-clean-fallback" "$transcript" "claude-missing-sections.txt" "$project_root" "$output_path" \
    "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" "missing heading: Working State"
}

scenario_interrupted_generic_rejected() {
  echo "Scenario 3: interrupted session rejects generic title and tags"
  setup_env interrupted
  local project_root="$TEST_ROOT/interrupted-repo"
  local transcript="$TEST_ROOT/transcript-interrupted.jsonl"
  local output_path="$LLM_HISTORY_VAULT_DIR/${TODAY_YYMMDD}-interrupted-repo.md"

  init_git_repo "$project_root"
  printf '%s\n' '# partial update' >> "$project_root/scripts/exit-orchestrator.sh"
  copy_quality_transcript "transcript-interrupted.jsonl" "$transcript" "$project_root"

  run_and_score "interrupted-fallback" "$transcript" "claude-generic.txt" "$project_root" "$output_path" \
    "cccccccc-cccc-cccc-cccc-cccccccccccc" "generic title"
}

scenario_noop_clarifying_rejected() {
  echo "Scenario 4: noop session rejects clarifying language and still renders a useful handoff"
  setup_env noop
  local project_root="$TEST_ROOT/noop-dir"
  local transcript="$TEST_ROOT/transcript-noop.jsonl"
  local output_path="$LLM_HISTORY_VAULT_DIR/${TODAY_YYMMDD}-noop-dir.md"
  local bundle_path="$TEST_ROOT/noop-bundle.json"
  local work_file="$TEST_ROOT/context-work.json"

  seed_project_tree "$project_root"
  copy_quality_transcript "transcript-noop.jsonl" "$transcript" "$project_root"
  build_worker_file "$work_file" "dddddddd-dddd-dddd-dddd-dddddddddddd" "$transcript" "$project_root" "$output_path"
  python3 "$CONTEXT_SCRIPT" "$work_file" > "$bundle_path"
  assert_jq '.repo.is_git == false' "$bundle_path"

  run_and_score "noop-fallback" "$transcript" "claude-clarifying.txt" "$project_root" "$output_path" \
    "dddddddd-dddd-dddd-dddd-dddddddddddd" "forbidden conversational language"
}

scenario_git_heavy_good() {
  echo "Scenario 5: git-heavy session accepts grounded output with command facts"
  setup_env git-heavy
  local project_root="$TEST_ROOT/git-heavy-repo"
  local transcript="$TEST_ROOT/transcript-git-heavy.jsonl"
  local output_path="$LLM_HISTORY_VAULT_DIR/${TODAY_YYMMDD}-git-heavy-repo.md"
  local bundle_path="$TEST_ROOT/git-heavy-bundle.json"
  local work_file="$TEST_ROOT/context-work.json"

  init_git_repo "$project_root"
  printf '%s\n' '# git-heavy update' >> "$project_root/scripts/exit-audit.sh"
  copy_quality_transcript "transcript-git-heavy.jsonl" "$transcript" "$project_root"
  build_worker_file "$work_file" "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee" "$transcript" "$project_root" "$output_path"
  python3 "$CONTEXT_SCRIPT" "$work_file" > "$bundle_path"
  assert_jq '.tools.bash_commands | index("git push origin main") != null' "$bundle_path"
  assert_jq '.tools.likely_checks | index("gitleaks detect --no-banner -q") != null' "$bundle_path"

  run_and_score "git-heavy-good" "$transcript" "claude-grounded-git.txt" "$project_root" "$output_path" \
    "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
}

write_aggregate_report() {
  mkdir -p "$REPORT_DIR"
  python3 - <<'PY' "$REPORT_DIR/last-resume-readiness-report.json" "${SCENARIO_REPORTS[@]}"
import json
import sys

output_path = sys.argv[1]
reports = []
for path in sys.argv[2:]:
    with open(path, "r", encoding="utf-8") as handle:
        reports.append(json.load(handle))

summary = {
    "generated_at": __import__("datetime").datetime.now().isoformat(),
    "scenario_count": len(reports),
    "passed": all(report.get("passed") for report in reports),
    "reports": reports,
}

with open(output_path, "w", encoding="utf-8") as handle:
    json.dump(summary, handle, indent=2)
PY

  assert_jq '.passed == true' "$REPORT_DIR/last-resume-readiness-report.json"
}

scenario_code_heavy_good
scenario_research_clean_missing_sections
scenario_interrupted_generic_rejected
scenario_noop_clarifying_rejected
scenario_git_heavy_good
write_aggregate_report

echo "resume-readiness tests passed"
