#!/usr/bin/env bash
# llm-history-worker.sh — Detached worker that generates and saves LLM history.
# Launched by llm-history-save.sh via nohup; survives parent exit/SIGHUP.
# Reads all input from a temp work file (JSON) passed as $1.
#
# Rendering is deterministic: we build the markdown directly from the grounded
# context bundle produced by llm-history-context.py. There is no nested
# `claude -p` call. See references/template.md for the output shape.
#
# Failure handling: if any step of the standard render fails during SessionEnd,
# the worker writes an emergency file containing the raw work + context JSON
# so the session is never silently lost. See Phase 1.7 in the plan file.

set -uo pipefail

unset CLAUDECODE 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOGFILE="${LLM_HISTORY_WORKER_LOGFILE:-/tmp/llm-history-worker.log}"
WORK_FILE="${1:?Usage: llm-history-worker.sh <work-file>}"
CONTEXT_HELPER="${LLM_HISTORY_CONTEXT_HELPER:-$SCRIPT_DIR/llm-history-context.py}"
CONTEXT_FILE=""
RENDER_MODE="${LLM_HISTORY_RENDER_MODE:-standard}"

mkdir -p "$(dirname "$LOGFILE")"

log() { echo "[$(date -Iseconds)] $*" >> "$LOGFILE" 2>/dev/null; }
cleanup() { rm -f "$WORK_FILE" "${CONTEXT_FILE:-}" 2>/dev/null; }
trap cleanup EXIT

build_fallback_summary() {
  jq -r '
    def bullets(items): if ((items // []) | length) == 0 then "- None captured." else (items | join("\n")) end;
    "## Resume Snapshot\n\n"
    + bullets(.resume_packet.snapshot_lines)
    + "\n\n## Task Ledger\n\n"
    + "### DONE\n\n"
    + bullets(.resume_packet.task_ledger.done)
    + "\n\n### PARTIALLY DONE\n\n"
    + bullets(.resume_packet.task_ledger.partial)
    + "\n\n### NOT DONE\n\n"
    + bullets(.resume_packet.task_ledger.not_done)
    + "\n\n## Workspace Truth\n\n"
    + bullets(.resume_packet.workspace_truth_lines)
    + "\n\n## Decisions And Rationale\n\n"
    + bullets(.resume_packet.decision_lines)
    + "\n\n## Validation Evidence\n\n"
    + bullets(.resume_packet.validation_lines)
    + "\n\n## Risks, Blockers, And Unknowns\n\n"
    + bullets(.resume_packet.risk_lines)
    + "\n\n## Do Not Redo\n\n"
    + bullets(.resume_packet.do_not_redo_lines)
  ' "$CONTEXT_FILE"
}

write_emergency_dump() {
  # Arguments: exit_code, stage, detail
  local exit_code="$1"
  local stage="$2"
  local detail="$3"
  local session_short="${SESSION_ID:0:8}"
  [ -z "$session_short" ] && session_short="unknown"

  local vault_dir
  vault_dir="$(dirname "${FILE_PATH:-$LOGFILE}")"
  mkdir -p "$vault_dir" 2>/dev/null

  local slug
  slug="$(basename "${FILE_PATH:-session}" .md | sed -E 's/-[0-9]+$//')"
  local emergency_path="${vault_dir}/${slug}-EMERGENCY-${session_short}.md"

  {
    printf '%s\n' '---'
    printf 'saved_at: %s\n' "${SAVED_AT:-$(date -Iseconds)}"
    printf 'session_id: %s\n' "${SESSION_ID:-unknown}"
    printf 'cwd: %s\n' "${CWD:-unknown}"
    printf 'trigger: session-end-emergency\n'
    printf 'failed_stage: %s\n' "$stage"
    printf 'exit_code: %s\n' "$exit_code"
    printf '%s\n' '---'
    printf '\n# Emergency Context Dump\n\n'
    printf 'Render failed at stage `%s` with exit code %s (%s). Structured handoff unavailable.\n\n' \
      "$stage" "$exit_code" "$detail"
    printf 'Raw work file contents:\n\n```json\n'
    if [ -r "$WORK_FILE" ]; then cat "$WORK_FILE"; else printf '(work file unreadable)\n'; fi
    printf '\n```\n\nRaw context bundle (if available):\n\n```json\n'
    if [ -n "$CONTEXT_FILE" ] && [ -r "$CONTEXT_FILE" ]; then cat "$CONTEXT_FILE"; else printf '(context bundle unavailable)\n'; fi
    printf '\n```\n'
  } > "$emergency_path" 2>>"$LOGFILE"

  log "EMERGENCY session=${SESSION_ID:-unknown} stage=$stage exit=$exit_code -> $emergency_path"

  if [ -n "${LLM_HISTORY_RESULT_FILE:-}" ]; then
    {
      printf 'result=error\n'
      printf 'detail=render-failed-%s\n' "$stage"
      printf 'file_path=%s\n' "$emergency_path"
      printf 'session_id=%s\n' "${SESSION_ID:-unknown}"
      printf 'hook_event=%s\n' "${HOOK_EVENT:-unknown}"
    } > "$LLM_HISTORY_RESULT_FILE" 2>>"$LOGFILE"
  fi
}

render_handoff() {
  # Returns non-zero on the first failing step; caller handles the emergency dump.

  if [ -f "$LOGFILE" ] && [ "$(wc -l < "$LOGFILE" | tr -d ' ')" -gt 200 ]; then
    tail -50 "$LOGFILE" > "${LOGFILE}.tmp" && mv "${LOGFILE}.tmp" "$LOGFILE"
  fi

  # --- Parse work file ---
  eval "$(jq -r '
    "TRANSCRIPT_PATH=" + (.transcript_path | @sh),
    "CWD=" + (.cwd | @sh),
    "HOOK_EVENT=" + (.hook_event | @sh),
    "SESSION_ID=" + (.session_id | @sh),
    "FILE_PATH=" + (.file_path | @sh),
    "BASE_NAME=" + (.base_name | @sh),
    "DATE_ISO=" + (.date_iso | @sh),
    "SAVED_AT=" + ((.saved_at // "") | @sh),
    "HOOK_INPUT_JSON=" + (.hook_input_json | @sh)' "$WORK_FILE")" || return 10

  [ -z "$SAVED_AT" ] && SAVED_AT=$(date -Iseconds)

  log "START session=$SESSION_ID event=$HOOK_EVENT render_mode=$RENDER_MODE"

  PROJECT_DIR="${CWD/#\/Users\/naqi.khan/~}"
  MODEL_LABEL="auto-saved (grounded deterministic)"

  CONTEXT_FILE=$(mktemp /tmp/llm-history-context-XXXXXX) || return 20
  if ! python3 "$CONTEXT_HELPER" "$WORK_FILE" > "$CONTEXT_FILE" 2>>"$LOGFILE"; then
    return 21
  fi
  if [ ! -s "$CONTEXT_FILE" ]; then
    return 22
  fi

  eval "$(jq -r '
    "SESSION_NAME=" + ((.session.session_name // "") | @sh),
    "PROJECT_SLUG=" + (.session.project_slug | @sh),
    "FALLBACK_TITLE=" + (.derived.fallback_title | @sh),
    "FALLBACK_STATUS=" + (.derived.fallback_status | @sh),
    "FALLBACK_TAGS_CSV=" + ((.derived.grounded_tags | join(",")) | @sh)' "$CONTEXT_FILE")" || return 30

  SUMMARY=$(build_fallback_summary) || return 31
  TITLE="$FALLBACK_TITLE"
  STATUS="$FALLBACK_STATUS"
  TAGS_CSV="$FALLBACK_TAGS_CSV"

  case "$STATUS" in completed|in-progress|blocked) ;; *) STATUS="in-progress" ;; esac

  if [ -n "$TAGS_CSV" ]; then
    TAGS_YAML=$(echo "$TAGS_CSV" | tr ',' '\n' | sed 's/^ *//; s/ *$//' | sed 's/^/  - /')
  else
    TAGS_YAML=$(jq -r '.derived.grounded_tags | map("  - " + .) | join("\n")' "$CONTEXT_FILE") || return 32
  fi

  # Belt-and-suspenders title sanitation in case a future code path skips
  # sanitize_title_text in context.py.
  TITLE=$(printf '%s' "$TITLE" | awk 'NR==1 {sub(/^[[:space:]]*#+[[:space:]]*/, ""); print; exit}' | cut -c1-80)
  TITLE_YAML=$(echo "$TITLE" | sed "s/'/''/g")

  cat > "$FILE_PATH" << FRONTMATTER_EOF || return 40
---
date: ${DATE_ISO}
saved_at: ${SAVED_AT}
title: '${TITLE_YAML}'
model: ${MODEL_LABEL}
project: ${PROJECT_DIR}
session_id: ${SESSION_ID}
session_name: ${SESSION_NAME}
status: ${STATUS}
trigger: ${HOOK_EVENT}
tags:
${TAGS_YAML}
---

FRONTMATTER_EOF

  printf '# %s\n\n%s\n' "$TITLE" "$SUMMARY" >> "$FILE_PATH" || return 41

  log "DONE session=$SESSION_ID -> $FILE_PATH"
  return 0
}

# Pre-populate fields that the emergency handler references, in case rendering
# fails before the work-file parse completes.
TRANSCRIPT_PATH=""
CWD=""
HOOK_EVENT=""
SESSION_ID=""
FILE_PATH=""
BASE_NAME=""
DATE_ISO=""
SAVED_AT=""

render_handoff
rc=$?

if [ "$rc" -ne 0 ]; then
  case "$rc" in
    10)       stage="parse-work-file";  detail="jq failed on work file" ;;
    20|21|22) stage="context-bundle";   detail="llm-history-context.py failed or produced empty output" ;;
    30|31|32) stage="build-summary";    detail="jq failed while building fallback summary" ;;
    40|41)    stage="write-file";       detail="could not write vault file" ;;
    *)        stage="unknown";          detail="unexpected exit code $rc" ;;
  esac
  log "FAIL session=${SESSION_ID:-unknown} stage=$stage rc=$rc detail=$detail"
  write_emergency_dump "$rc" "$stage" "$detail"
  exit 1
fi

exit 0
