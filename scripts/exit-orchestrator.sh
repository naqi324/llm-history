#!/usr/bin/env bash
# exit-orchestrator.sh — Authoritative SessionEnd pipeline for git ops then llm-history.
# Registered as a synchronous SessionEnd hook in ~/.claude/settings.json.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOGFILE="${CLAUDE_EXIT_LOGFILE:-/tmp/claude-exit-orchestrator.log}"
GIT_SCRIPT="${CLAUDE_EXIT_GIT_SCRIPT:-/Users/naqi.khan/git/CLAUDE-md/.claude/hooks/auto-git-commit.sh}"
HISTORY_SCRIPT="${CLAUDE_EXIT_HISTORY_SCRIPT:-$SCRIPT_DIR/llm-history-save.sh}"
HISTORY_RENDER_MODE="${CLAUDE_EXIT_HISTORY_RENDER_MODE:-session-end-sync}"

mkdir -p "$(dirname "$LOGFILE")"

INPUT=$(cat)
eval "$(printf '%s' "$INPUT" | jq -r '
  "SESSION_ID=" + ((.session_id // "") | @sh),
  "CWD=" + ((.cwd // "") | @sh),
  "HOOK_EVENT=" + ((.hook_event_name // "SessionEnd") | @sh)')"

epoch_ms() { printf '%s000' "$(date +%s)"; }

log_json() {
  jq -cn \
    --arg timestamp "$(date -Iseconds)" \
    --arg session_id "$SESSION_ID" \
    --arg cwd "$CWD" \
    --arg hook_event "$HOOK_EVENT" \
    "$@" >> "$LOGFILE"
}

read_result_value() {
  local path="$1"
  local key="$2"
  [ -f "$path" ] || return 0
  awk -F= -v target="$key" '$1 == target {sub(/^[^=]*=/, "", $0); print $0; exit}' "$path"
}

run_phase() {
  local phase="$1"
  local script_path="$2"
  local result_prefix="$3"
  local result_file
  local start_epoch
  local end_epoch
  local phase_exit=0

  result_file=$(mktemp /tmp/claude-exit-"$phase"-XXXXXX)
  start_epoch=$(epoch_ms)

  if [ "$phase" = "git" ]; then
    if printf '%s' "$INPUT" | AUTO_GIT_RESULT_FILE="$result_file" "$script_path"; then
      phase_exit=0
    else
      phase_exit=$?
    fi
  else
    if printf '%s' "$INPUT" | LLM_HISTORY_RESULT_FILE="$result_file" LLM_HISTORY_SYNC=1 LLM_HISTORY_RENDER_MODE="$HISTORY_RENDER_MODE" "$script_path"; then
      phase_exit=0
    else
      phase_exit=$?
    fi
  fi

  end_epoch=$(epoch_ms)

  local duration_ms=$((end_epoch - start_epoch))
  local result detail output_path repo_root branch
  result=$(read_result_value "$result_file" result)
  detail=$(read_result_value "$result_file" detail)
  output_path=$(read_result_value "$result_file" file_path)
  repo_root=$(read_result_value "$result_file" repo_root)
  branch=$(read_result_value "$result_file" branch)

  [ -z "$result" ] && result=$([ "$phase_exit" -eq 0 ] && printf 'success' || printf 'error')
  rm -f "$result_file"

  log_json \
    --arg phase "$phase" \
    --arg result "$result" \
    --arg detail "$detail" \
    --arg output_path "$output_path" \
    --arg repo_root "$repo_root" \
    --arg branch "$branch" \
    --arg history_render_mode "$HISTORY_RENDER_MODE" \
    --argjson duration_ms "$duration_ms" \
    '{timestamp:$timestamp, session_id:$session_id, cwd:$cwd, hook_event:$hook_event, phase:$phase, result:$result, detail:$detail, output_path:$output_path, repo_root:$repo_root, branch:$branch, history_render_mode:(if $phase == "history" then $history_render_mode else "" end), duration_ms:$duration_ms}'

  printf -v "${result_prefix}_RESULT" '%s' "$result"
  printf -v "${result_prefix}_DETAIL" '%s' "$detail"
  printf -v "${result_prefix}_EXIT" '%s' "$phase_exit"
  printf -v "${result_prefix}_OUTPUT_PATH" '%s' "$output_path"
  printf -v "${result_prefix}_REPO_ROOT" '%s' "$repo_root"
  printf -v "${result_prefix}_BRANCH" '%s' "$branch"
}

overall_result="success"
log_json '{timestamp:$timestamp, session_id:$session_id, cwd:$cwd, hook_event:$hook_event, phase:"pipeline", state:"start"}'

run_phase "git" "$GIT_SCRIPT" "GIT"
run_phase "history" "$HISTORY_SCRIPT" "HISTORY"

if [ "$GIT_RESULT" = "error" ] || [ "$HISTORY_RESULT" = "error" ] || [ "$GIT_EXIT" -ne 0 ] || [ "$HISTORY_EXIT" -ne 0 ]; then
  overall_result="error"
fi

log_json \
  --arg git_result "$GIT_RESULT" \
  --arg git_detail "$GIT_DETAIL" \
  --arg git_repo_root "$GIT_REPO_ROOT" \
  --arg git_branch "$GIT_BRANCH" \
  --arg history_result "$HISTORY_RESULT" \
  --arg history_detail "$HISTORY_DETAIL" \
  --arg history_output_path "$HISTORY_OUTPUT_PATH" \
  --arg history_render_mode "$HISTORY_RENDER_MODE" \
  --arg overall "$overall_result" \
  '{timestamp:$timestamp, session_id:$session_id, cwd:$cwd, hook_event:$hook_event, phase:"pipeline", state:"done", git_result:$git_result, git_detail:$git_detail, git_repo_root:$git_repo_root, git_branch:$git_branch, history_result:$history_result, history_detail:$history_detail, history_output_path:$history_output_path, history_render_mode:$history_render_mode, overall:$overall}'

if [ "$overall_result" = "error" ]; then
  exit 1
fi

exit 0
