#!/usr/bin/env bash
# llm-history-worker.sh — Detached worker that generates and saves LLM history
# Launched by llm-history-save.sh via nohup; survives parent exit/SIGHUP.
# Reads all input from a temp work file (JSON) passed as $1.

set -euo pipefail

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
FIRST_PROMPT=$(jq -r '.first_prompt' "$WORK_FILE")
FILE_PATH=$(jq -r '.file_path' "$WORK_FILE")
BASE_NAME=$(jq -r '.base_name' "$WORK_FILE")
DATE_ISO=$(jq -r '.date_iso' "$WORK_FILE")
HOOK_INPUT_JSON=$(jq -r '.hook_input_json' "$WORK_FILE")

log "START session=$SESSION_ID event=$HOOK_EVENT"

# --- Generate summary via claude -p ---

# Shorten home path for display
PROJECT_DIR="${CWD/#\/Users\/naqi.khan/~}"

# Extract only text content from transcript (skip tool calls, tool results, snapshots)
TRANSCRIPT_TEXT=$(jq -r '
  select(.type == "user" or .type == "assistant")
  | .message.content[]?
  | select(.type == "text")
  | .text
' "$TRANSCRIPT_PATH" 2>/dev/null | tail -3000)

# If no text content extracted, use last_assistant_message as fallback input
if [ -z "$TRANSCRIPT_TEXT" ]; then
  TRANSCRIPT_TEXT=$(echo "$HOOK_INPUT_JSON" | jq -r '.last_assistant_message // ""')
fi

# Call claude -p with timeout to prevent orphan workers on API failure
SUMMARY=$(echo "$TRANSCRIPT_TEXT" | timeout 90 claude -p \
  --model sonnet \
  --no-session-persistence \
  --strict-mcp-config \
  "You are generating a session context file for future Claude Code session resumption.
Analyze this conversation text and produce ONLY the markdown body content (no YAML frontmatter — I will add that separately).

Use exactly these sections:

## Executive Summary
(2-4 sentences: what was accomplished, what the session was about)

## Key Decisions
(Bulleted list. Each bullet: **Decision**: Rationale. Omit if no significant decisions were made.)

## In-Progress Work
(Current state of incomplete work with enough detail to resume. Omit if everything was completed.)

## Relevant Files
(Bulleted list of file paths that were created/modified, with brief notes on what was done. Omit if none.)

## Next Steps
(Numbered list of specific actionable items remaining. Always include this section.)

## Warnings and Blockers
(Any caveats, failed approaches, or blockers the next session must know. Omit if none.)

Rules:
- Be concise. Focus on what someone needs to pick up this work in a fresh session.
- Never include raw tool outputs or verbose logs.
- Include file paths as \`inline code\`.
- Keep under 200 lines total." 2>/dev/null) || true

# Fallback if claude -p fails or times out
if [ -z "$SUMMARY" ]; then
  LAST_MSG=$(echo "$HOOK_INPUT_JSON" | jq -r '.last_assistant_message // ""')
  # Handle missing last_assistant_message (e.g., SessionEnd trigger)
  if [ -z "$LAST_MSG" ]; then
    LAST_MSG="(Session context unavailable — triggered via $HOOK_EVENT)"
  fi
  SUMMARY="## Executive Summary

Auto-save triggered ($HOOK_EVENT) for project \`${PROJECT_DIR}\` but detailed summary generation was unavailable.

## Session Topic

${FIRST_PROMPT:-No user prompt extracted.}

## Last Assistant Message

$LAST_MSG

## Next Steps

1. Review the session transcript for full context.
2. Re-run \`/llm-history\` manually in a new session for a richer summary."
fi

# --- Write the output file ---

cat > "$FILE_PATH" << FRONTMATTER_EOF
---
date: ${DATE_ISO}
model: auto-saved (sonnet)
project: ${PROJECT_DIR}
session_id: ${SESSION_ID}
trigger: ${HOOK_EVENT}
tags:
  - llm-history
  - auto-save
---

# ${BASE_NAME}

${SUMMARY}
FRONTMATTER_EOF

log "DONE session=$SESSION_ID -> $FILE_PATH"

exit 0
