#!/usr/bin/env bash
# llm-history-save.sh — Auto-save session context to Obsidian vault
# Called by Stop, SessionEnd, and PreCompact hooks via ~/.claude/settings.json
# Receives hook JSON on stdin with session_id, transcript_path, cwd, etc.
# This is the fast dispatcher — it runs guards and forks a detached worker
# for the slow claude -p summarization.

set -euo pipefail
# NOTE: pipefail means ALL command substitutions with jq/grep pipelines
# must use || true — jq returns non-zero on any malformed JSONL line.

LOGFILE="/tmp/llm-history-hook.log"
log() { echo "[$(date -Iseconds)] $*" >> "$LOGFILE" 2>/dev/null; }
trap 'log "ERROR at line $LINENO (session=${SESSION_ID:-unknown})"' ERR

# Trim log when > 500 lines
if [ -f "$LOGFILE" ] && [ "$(wc -l < "$LOGFILE" | tr -d ' ')" -gt 500 ]; then
  tail -100 "$LOGFILE" > "${LOGFILE}.tmp" && mv "${LOGFILE}.tmp" "$LOGFILE"
fi

VAULT_DIR="/Users/naqi.khan/Documents/Obsidian/LLM History"
LOCKDIR="/tmp/llm-history-locks"

# Read hook input from stdin
INPUT=$(cat)
log "START input_length=${#INPUT}"

# Parse fields from hook JSON
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""')
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // ""')
CWD=$(echo "$INPUT" | jq -r '.cwd // ""')
HOOK_EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // ""')
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false')

# --- Guards ---

# Guard 1: Prevent infinite loops when Stop hook triggers Claude continuation
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
  log "SKIP: stop_hook_active=true session=$SESSION_ID"
  exit 0
fi

# Guard 2: For PreCompact, only trigger on automatic compaction (not manual /compact)
if [ "$HOOK_EVENT" = "PreCompact" ]; then
  TRIGGER=$(echo "$INPUT" | jq -r '.trigger // ""')
  if [ "$TRIGGER" != "auto" ]; then
    log "SKIP: PreCompact manual trigger session=$SESSION_ID"
    exit 0
  fi
fi

# Guard 3: Transcript must exist and be readable
if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then
  log "SKIP: transcript missing or unreadable ($TRANSCRIPT_PATH) session=$SESSION_ID"
  exit 0
fi

# Guard 4: Skip trivial sessions (fewer than 10 lines)
TRANSCRIPT_LINES=$(wc -l < "$TRANSCRIPT_PATH" | tr -d ' ')
if [ "$TRANSCRIPT_LINES" -lt 10 ]; then
  log "SKIP: transcript too short ($TRANSCRIPT_LINES lines) session=$SESSION_ID"
  exit 0
fi

# Guard 5: Session deduplication — event-agnostic lock shared by Stop and SessionEnd
mkdir -p "$LOCKDIR"
LOCK_FILE=""
if [ -n "$SESSION_ID" ]; then
  LOCK_FILE="$LOCKDIR/${SESSION_ID}-save.saved"
  if [ -f "$LOCK_FILE" ]; then
    log "SKIP: already saved (lock=$LOCK_FILE) session=$SESSION_ID"
    exit 0
  fi
fi

# Guard 6: Skip if this session already has a saved file (manual /llm-history or prior hook)
if [ -n "$SESSION_ID" ]; then
  EXISTING=$(grep -rl "session_id: ${SESSION_ID}" "$VAULT_DIR" 2>/dev/null | head -1) || true
  if [ -n "$EXISTING" ]; then
    log "SKIP: Guard 6 existing=$EXISTING session=$SESSION_ID"
    [ -n "$LOCK_FILE" ] && touch "$LOCK_FILE"
    exit 0
  fi
fi

# --- Generate filename ---

DATE_YYMMDD=$(date +%y%m%d)
DATE_ISO=$(date +%Y-%m-%d)
SAVED_AT=$(date -Iseconds)

# Project slug from CWD basename (reliable — no JSONL parsing needed)
# The JSONL transcript stores user-typed prompts as tool_result content, not text blocks.
# The only text blocks in user messages are skill injection text, which produces
# broken slugs like "you-provide-structured-objective". CWD basename is always meaningful.
SLUG=$(basename "$CWD" 2>/dev/null \
  | tr '[:upper:]' '[:lower:]' \
  | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//' \
  | cut -c1-25)
[ -z "$SLUG" ] && SLUG="session"

# Keep FIRST_PROMPT for backward compat with current worker (removed in v2 worker)
FIRST_PROMPT="(project: $SLUG)"

# Deduplication: find next available filename
BASE_NAME="${DATE_YYMMDD}-${SLUG}"
mkdir -p "$VAULT_DIR"
FILE_PATH="${VAULT_DIR}/${BASE_NAME}.md"
COUNTER=2

while [ -f "$FILE_PATH" ]; do
  FILE_PATH="${VAULT_DIR}/${BASE_NAME}-${COUNTER}.md"
  COUNTER=$((COUNTER + 1))
done

# --- Claim lock and dispatch worker ---

# Create lock immediately (before forking) to prevent race between Stop and SessionEnd
if [ -n "$LOCK_FILE" ]; then
  touch "$LOCK_FILE"
fi

# Clean up stale temp files from crashed workers (older than 1 day)
find /tmp -name "llm-history-work-*.json" -mtime +1 -delete 2>/dev/null || true

# Write all collected data to a temp file for the worker
WORK_FILE=$(mktemp /tmp/llm-history-work-XXXXXX.json)
jq -n \
  --arg transcript_path "$TRANSCRIPT_PATH" \
  --arg cwd "$CWD" \
  --arg hook_event "$HOOK_EVENT" \
  --arg session_id "$SESSION_ID" \
  --arg first_prompt "$FIRST_PROMPT" \
  --arg slug "$SLUG" \
  --arg file_path "$FILE_PATH" \
  --arg base_name "$BASE_NAME" \
  --arg date_iso "$DATE_ISO" \
  --arg saved_at "$SAVED_AT" \
  --arg hook_input_json "$INPUT" \
  '{transcript_path: $transcript_path, cwd: $cwd, hook_event: $hook_event,
    session_id: $session_id, first_prompt: $first_prompt, slug: $slug,
    file_path: $file_path, base_name: $base_name, date_iso: $date_iso,
    saved_at: $saved_at, hook_input_json: $hook_input_json}' > "$WORK_FILE"

# Launch detached worker — survives parent exit/SIGHUP
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
nohup "$SCRIPT_DIR/llm-history-worker.sh" "$WORK_FILE" </dev/null >/dev/null 2>&1 &

log "DISPATCH: session=$SESSION_ID event=$HOOK_EVENT worker_pid=$! -> $FILE_PATH"

# Clean up old lock files (older than 2 days)
find "$LOCKDIR" -name "*.saved" -mtime +2 -delete 2>/dev/null || true

exit 0
