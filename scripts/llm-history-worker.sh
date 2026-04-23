#!/usr/bin/env bash
# llm-history-worker.sh — Detached worker that generates and saves LLM history.
# Launched by llm-history-save.sh via nohup; survives parent exit/SIGHUP.
# Reads all input from a temp work file (JSON) passed as $1.
#
# Rendering is deterministic: we build the markdown directly from the grounded
# context bundle produced by llm-history-context.py. There is no nested
# `claude -p` call. See references/template.md for the output shape.

set -euo pipefail

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
    def paragraph(items): items | map(select(length > 0)) | join(" ");
    def bullets(items): if (items | length) == 0 then "- unknown" else items | join("\n") end;
    def numbered(items): if (items | length) == 0 then "1. Review the grounded session facts and continue from the latest recorded state." else items | to_entries | map("\(.key + 1). \(.value)") | join("\n") end;
    "## Executive Summary\n\n"
    + paragraph(.derived.summary_sentences)
    + "\n\n## Working State\n\n"
    + bullets(.derived.working_state_lines)
    + "\n\n## Files Changed\n\n"
    + bullets(.derived.files_changed_lines)
    + "\n\n## Concrete Next Steps\n\n"
    + numbered(.derived.next_steps)
    + (if (.derived.failed_lines | length) > 0
        then "\n\n## Failed Approaches\n\n" + bullets(.derived.failed_lines)
        else ""
       end)
    + (if (.derived.warning_lines | length) > 0
        then "\n\n## Warnings\n\n" + bullets(.derived.warning_lines)
        else ""
       end)
  ' "$CONTEXT_FILE"
}

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
  "HOOK_INPUT_JSON=" + (.hook_input_json | @sh)' "$WORK_FILE")"

[ -z "$SAVED_AT" ] && SAVED_AT=$(date -Iseconds)

log "START session=$SESSION_ID event=$HOOK_EVENT render_mode=$RENDER_MODE"

PROJECT_DIR="${CWD/#\/Users\/naqi.khan/~}"
MODEL_LABEL="auto-saved (grounded deterministic)"

CONTEXT_FILE=$(mktemp /tmp/llm-history-context-XXXXXX)
python3 "$CONTEXT_HELPER" "$WORK_FILE" > "$CONTEXT_FILE"

eval "$(jq -r '
  "SESSION_NAME=" + ((.session.session_name // "") | @sh),
  "PROJECT_SLUG=" + (.session.project_slug | @sh),
  "FALLBACK_TITLE=" + (.derived.fallback_title | @sh),
  "FALLBACK_STATUS=" + (.derived.fallback_status | @sh),
  "FALLBACK_TAGS_CSV=" + ((.derived.grounded_tags | join(",")) | @sh)' "$CONTEXT_FILE")"

SUMMARY=$(build_fallback_summary)
TITLE="$FALLBACK_TITLE"
STATUS="$FALLBACK_STATUS"
TAGS_CSV="$FALLBACK_TAGS_CSV"

case "$STATUS" in completed|in-progress|blocked) ;; *) STATUS="in-progress" ;; esac

if [ -n "$TAGS_CSV" ]; then
  TAGS_YAML=$(echo "$TAGS_CSV" | tr ',' '\n' | sed 's/^ *//; s/ *$//' | sed 's/^/  - /')
else
  TAGS_YAML=$(jq -r '.derived.grounded_tags | map("  - " + .) | join("\n")' "$CONTEXT_FILE")
fi

TITLE_YAML=$(echo "$TITLE" | sed "s/'/''/g")

# --- Write the output file ---

cat > "$FILE_PATH" << FRONTMATTER_EOF
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

printf '# %s\n\n%s\n' "$TITLE" "$SUMMARY" >> "$FILE_PATH"

log "DONE session=$SESSION_ID -> $FILE_PATH"

exit 0
