#!/usr/bin/env bash
# llm-history-worker.sh — Detached worker that generates and saves LLM history
# Launched by llm-history-save.sh via nohup; survives parent exit/SIGHUP.
# Reads all input from a temp work file (JSON) passed as $1.
# v2: assistant-only extraction, structured metadata parsing, YAML-safe output.

set -euo pipefail
# NOTE: pipefail means ALL command substitutions with jq/grep pipelines
# must use || true — jq returns non-zero on any malformed JSONL line.

# Worker runs in its own process — independently unset CLAUDECODE
unset CLAUDECODE 2>/dev/null || true

LOGFILE="/tmp/llm-history-worker.log"
WORK_FILE="${1:?Usage: llm-history-worker.sh <work-file>}"

log() { echo "[$(date -Iseconds)] $*" >> "$LOGFILE" 2>/dev/null; }
cleanup() { rm -f "$WORK_FILE" 2>/dev/null; }
trap cleanup EXIT
trap 'log "ERROR: session=${SESSION_ID:-unknown} line=$LINENO"; exit 1' ERR

# Trim log when > 200 lines
if [ -f "$LOGFILE" ] && [ "$(wc -l < "$LOGFILE" | tr -d ' ')" -gt 200 ]; then
  tail -50 "$LOGFILE" > "${LOGFILE}.tmp" && mv "${LOGFILE}.tmp" "$LOGFILE"
fi

# --- Parse work file ---

TRANSCRIPT_PATH=$(jq -r '.transcript_path' "$WORK_FILE")
CWD=$(jq -r '.cwd' "$WORK_FILE")
HOOK_EVENT=$(jq -r '.hook_event' "$WORK_FILE")
SESSION_ID=$(jq -r '.session_id' "$WORK_FILE")
FILE_PATH=$(jq -r '.file_path' "$WORK_FILE")
BASE_NAME=$(jq -r '.base_name' "$WORK_FILE")
DATE_ISO=$(jq -r '.date_iso' "$WORK_FILE")
SAVED_AT=$(jq -r '.saved_at // ""' "$WORK_FILE")
HOOK_INPUT_JSON=$(jq -r '.hook_input_json' "$WORK_FILE")

# Fallback if saved_at missing (backward compat with pre-v2 dispatcher)
[ -z "$SAVED_AT" ] && SAVED_AT=$(date -Iseconds)

log "START session=$SESSION_ID event=$HOOK_EVENT"

# --- Generate summary via claude -p ---

# Shorten home path for display
PROJECT_DIR="${CWD/#\/Users\/naqi.khan/~}"

# Extract session name (Claude Code auto-assigns, e.g., "upgrade-llm-history-skill")
SESSION_NAME=$(jq -r 'select(.type == "custom-title") | .customTitle' "$TRANSCRIPT_PATH" 2>/dev/null | tail -1) || true

# Extract only assistant text from transcript — assistant messages describe actual
# work done. User messages contain mostly tool_results and skill injection text
# which pollutes the summary.
TRANSCRIPT_TEXT=$(jq -r '
  select(.type == "assistant")
  | .message.content[]?
  | select(.type == "text")
  | .text
' "$TRANSCRIPT_PATH" 2>>"$LOGFILE" | tail -3000) || { log "WARN: jq failed extracting transcript text"; true; }

# If no text content extracted, use last_assistant_message as fallback input
if [ -z "$TRANSCRIPT_TEXT" ]; then
  TRANSCRIPT_TEXT=$(echo "$HOOK_INPUT_JSON" | jq -r '.last_assistant_message // ""')
fi

# Load prompt from external file with inline fallback
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROMPT_FILE="$SCRIPT_DIR/../references/prompt.md"
if [ -f "$PROMPT_FILE" ]; then
  PROMPT_TEXT=$(cat "$PROMPT_FILE")
else
  log "WARN: prompt file missing ($PROMPT_FILE), using inline fallback"
  PROMPT_TEXT="You are generating a session handoff document for Claude Code session resumption.
Analyze this conversation and produce ONLY markdown body content (no YAML frontmatter).

FIRST LINE: TITLE: <descriptive 5-10 word title>
SECOND LINE: TAGS: <3-5 comma-separated lowercase tags>
THIRD LINE: STATUS: <completed|in-progress|blocked>

Then sections: Executive Summary (what/accomplished/remains), Key Decisions (chosen vs rejected + why), Working State (exact codebase state right now), Files Changed (path + specific change), Concrete Next Steps (exact commands, not vague), Failed Approaches (what didn't work + why), Warnings.
Write for a session that has NEVER seen this code. Every decision must include what was rejected. Every next step must include the exact command or file path. Under 300 lines."
fi

# Detect timeout command (GNU coreutils; not available on stock macOS)
run_with_timeout() {
  if command -v timeout &>/dev/null; then
    timeout 90 "$@"
  elif command -v gtimeout &>/dev/null; then
    gtimeout 90 "$@"
  else
    "$@"
  fi
}

# Call claude -p with timeout to prevent orphan workers on API failure
SUMMARY=$(echo "$TRANSCRIPT_TEXT" | run_with_timeout claude -p \
  --model sonnet \
  --no-session-persistence \
  --strict-mcp-config \
  "$PROMPT_TEXT" 2>/dev/null) || true

# --- Parse structured metadata from claude -p response ---

TITLE=""
TAGS_CSV=""
STATUS=""

if [ -n "$SUMMARY" ]; then
  TITLE=$(echo "$SUMMARY" | grep -m1 '^TITLE:' | sed 's/^TITLE: *//' | head -c 100) || true
  TAGS_CSV=$(echo "$SUMMARY" | grep -m1 '^TAGS:' | sed 's/^TAGS: *//') || true
  STATUS=$(echo "$SUMMARY" | grep -m1 '^STATUS:' | sed 's/^STATUS: *//' | tr '[:upper:]' '[:lower:]') || true

  # Strip metadata lines from body (portable — BSD sed doesn't support {cmd;cmd} grouping)
  SUMMARY=$(echo "$SUMMARY" | sed '/^TITLE:/d; /^TAGS:/d; /^STATUS:/d')
fi

# --- Fallback if claude -p failed or timed out ---

if [ -z "$SUMMARY" ]; then
  log "WARN: claude -p failed, building structured fallback"

  # Last assistant text blocks (the actual work descriptions)
  RECENT_CONTEXT=$(jq -r '
    select(.type == "assistant")
    | .message.content[]?
    | select(.type == "text")
    | .text
  ' "$TRANSCRIPT_PATH" 2>>"$LOGFILE" | tail -80) || true

  LAST_MSG=$(echo "$HOOK_INPUT_JSON" | jq -r '.last_assistant_message // ""')
  [ -z "$LAST_MSG" ] && LAST_MSG="(Session context unavailable — triggered via $HOOK_EVENT)"

  SUMMARY="## Executive Summary

Auto-save triggered ($HOOK_EVENT) for project \`${PROJECT_DIR}\`. LLM summarization was unavailable; this is a structured extraction from the transcript.

## Recent Work Context

${RECENT_CONTEXT:-No assistant text extracted.}

## Last Assistant Message

$LAST_MSG

## Next Steps

1. Review this file and re-run \`/llm-history\` manually for a richer summary."

  TITLE="${PROJECT_DIR} — auto-save ($HOOK_EVENT)"
  STATUS="unknown"
fi

# --- Validate and default metadata ---

case "$STATUS" in completed|in-progress|blocked) ;; *) STATUS="unknown" ;; esac
[ -z "$TITLE" ] && TITLE="${PROJECT_DIR} session"

# Convert tags CSV to YAML list
if [ -n "$TAGS_CSV" ]; then
  TAGS_YAML=$(echo "$TAGS_CSV" | tr ',' '\n' | sed 's/^ *//; s/ *$//' | sed 's/^/  - /')
else
  TAGS_YAML="  - llm-history
  - auto-save"
fi

# YAML-safe title: single-quote with '' escaping for embedded single quotes
TITLE_YAML=$(echo "$TITLE" | sed "s/'/''/g")

# --- Write the output file ---

# Frontmatter with controlled variable expansion
cat > "$FILE_PATH" << FRONTMATTER_EOF
---
date: ${DATE_ISO}
saved_at: ${SAVED_AT}
title: '${TITLE_YAML}'
model: auto-saved (sonnet)
project: ${PROJECT_DIR}
session_id: ${SESSION_ID}
session_name: ${SESSION_NAME}
status: ${STATUS}
trigger: ${HOOK_EVENT}
tags:
${TAGS_YAML}
---

FRONTMATTER_EOF

# Append H1 title and body using printf to avoid shell expansion in SUMMARY
printf '# %s\n\n%s\n' "$TITLE" "$SUMMARY" >> "$FILE_PATH"

log "DONE session=$SESSION_ID -> $FILE_PATH"

exit 0
