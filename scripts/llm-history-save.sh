#!/usr/bin/env bash
# llm-history-save.sh — Auto-save session context to Obsidian vault
# Called by Stop and PreCompact hooks via ~/.claude/settings.json
# Receives hook JSON on stdin with session_id, transcript_path, cwd, etc.

set -euo pipefail

# Allow claude -p to run from within hook context (hooks inherit CLAUDECODE env var)
unset CLAUDECODE 2>/dev/null || true

VAULT_DIR="/Users/naqi.khan/Documents/Obsidian/LLM History"
LOCKDIR="/tmp/llm-history-locks"

# Read hook input from stdin
INPUT=$(cat)

# Parse fields from hook JSON
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""')
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // ""')
CWD=$(echo "$INPUT" | jq -r '.cwd // ""')
HOOK_EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // ""')
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false')

# --- Guards ---

# Guard 1: Prevent infinite loops when Stop hook triggers Claude continuation
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
  exit 0
fi

# Guard 2: For PreCompact, only trigger on automatic compaction (not manual /compact)
if [ "$HOOK_EVENT" = "PreCompact" ]; then
  TRIGGER=$(echo "$INPUT" | jq -r '.trigger // ""')
  if [ "$TRIGGER" != "auto" ]; then
    exit 0
  fi
fi

# Guard 3: Transcript must exist and be readable
if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then
  exit 0
fi

# Guard 4: Skip trivial sessions (fewer than 10 lines)
TRANSCRIPT_LINES=$(wc -l < "$TRANSCRIPT_PATH" | tr -d ' ')
if [ "$TRANSCRIPT_LINES" -lt 10 ]; then
  exit 0
fi

# Guard 5: Session deduplication — skip if already saved for this session+event
mkdir -p "$LOCKDIR"
LOCK_FILE=""
if [ -n "$SESSION_ID" ]; then
  LOCK_FILE="$LOCKDIR/${SESSION_ID}-${HOOK_EVENT}.saved"
  if [ -f "$LOCK_FILE" ]; then
    exit 0
  fi
fi

# Guard 6: Skip if this session already has a saved file (manual /llm-history or prior hook)
if [ -n "$SESSION_ID" ]; then
  EXISTING=$(grep -rl "session_id: ${SESSION_ID}" "$VAULT_DIR" 2>/dev/null | head -1)
  if [ -n "$EXISTING" ]; then
    [ -n "$LOCK_FILE" ] && touch "$LOCK_FILE"
    exit 0
  fi
fi

# --- Generate filename ---

DATE_YYMMDD=$(date +%y%m%d)
DATE_ISO=$(date +%Y-%m-%d)

# Extract slug from the first substantive user message in the transcript
# Filter out system-reminders, skill instructions, XML tags, and markdown headers
FIRST_PROMPT=$(jq -r '
  select(.type == "user")
  | .message.content[]?
  | select(.type == "text")
  | .text
' "$TRANSCRIPT_PATH" 2>/dev/null \
  | { grep -v '^\[' || true; } \
  | { grep -v '^<' || true; } \
  | { grep -v -i '^base directory' || true; } \
  | { grep -v '^#' || true; } \
  | { grep -v '^\s*$' || true; } \
  | head -1 \
  | cut -c1-200)

if [ -z "$FIRST_PROMPT" ]; then
  SLUG="session"
else
  # Generate slug: lowercase, strip non-alnum, take first 4 words, kebab-case
  SLUG=$(echo "$FIRST_PROMPT" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9 ]//g' \
    | sed 's/  */ /g' \
    | awk '{for(i=1;i<=NF&&i<=4;i++) printf "%s-", $i}' \
    | sed 's/-$//' \
    | cut -c1-40)
fi

if [ -z "$SLUG" ]; then
  SLUG="session"
fi

# Deduplication: find next available filename
BASE_NAME="${DATE_YYMMDD}-${SLUG}"
mkdir -p "$VAULT_DIR"
FILE_PATH="${VAULT_DIR}/${BASE_NAME}.md"
COUNTER=2

while [ -f "$FILE_PATH" ]; do
  FILE_PATH="${VAULT_DIR}/${BASE_NAME}-${COUNTER}.md"
  COUNTER=$((COUNTER + 1))
done

# --- Generate summary via claude -p ---

# Shorten home path for display
PROJECT_DIR="${CWD/#\/Users\/naqi.khan/~}"

# Extract only text content from transcript (skip tool calls, tool results, snapshots)
# This dramatically reduces size vs sending raw JSONL
TRANSCRIPT_TEXT=$(jq -r '
  select(.type == "user" or .type == "assistant")
  | .message.content[]?
  | select(.type == "text")
  | .text
' "$TRANSCRIPT_PATH" 2>/dev/null | tail -3000)

# If no text content extracted, use last_assistant_message as fallback input
if [ -z "$TRANSCRIPT_TEXT" ]; then
  TRANSCRIPT_TEXT=$(echo "$INPUT" | jq -r '.last_assistant_message // ""')
fi

# Call claude in print mode to generate the summary body
SUMMARY=$(echo "$TRANSCRIPT_TEXT" | claude -p \
  --model sonnet \
  --no-session-persistence \
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

# Fallback if claude -p fails
if [ -z "$SUMMARY" ]; then
  LAST_MSG=$(echo "$INPUT" | jq -r '.last_assistant_message // "No summary available."')
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

# Mark session as saved for dedup
if [ -n "$LOCK_FILE" ]; then
  touch "$LOCK_FILE"
fi

# Clean up old lock files (older than 2 days)
find "$LOCKDIR" -name "*.saved" -mtime +2 -delete 2>/dev/null || true

exit 0
