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

# Guard 5: Unified session deduplication
# Handles three cases:
# (a) First save for this session → proceed
# (b) Resumed session with significant new work (50+ JSONL lines growth) → re-save with -2 suffix
# (c) Same session, no meaningful growth → skip
# The vault grep only runs once per session (when no lock file exists yet).
# After that, the lock file tracks the baseline for growth-based re-save decisions.
mkdir -p "$LOCKDIR"
LOCK_FILE=""
if [ -n "$SESSION_ID" ]; then
  LOCK_FILE="$LOCKDIR/${SESSION_ID}-save.saved"
  if [ -f "$LOCK_FILE" ]; then
    PREV_LINES=$(cat "$LOCK_FILE" 2>/dev/null | tr -d ' ')
    if [ -n "$PREV_LINES" ] && [ "$TRANSCRIPT_LINES" -gt "$((PREV_LINES + 50))" ]; then
      log "RESAVE: transcript grew from $PREV_LINES to $TRANSCRIPT_LINES lines session=$SESSION_ID"
    else
      log "SKIP: no significant growth (prev=${PREV_LINES:-0} now=$TRANSCRIPT_LINES) session=$SESSION_ID"
      exit 0
    fi
  else
    # No lock file — check if vault already has this session (e.g., from manual /llm-history or post-reboot)
    EXISTING=$(grep -rl "session_id: ${SESSION_ID}" "$VAULT_DIR" 2>/dev/null | head -1) || true
    if [ -n "$EXISTING" ]; then
      log "SKIP: vault has existing file (no lock), setting lock session=$SESSION_ID"
      echo "$TRANSCRIPT_LINES" > "$LOCK_FILE"
      exit 0
    fi
    log "ALLOW: first save session=$SESSION_ID"
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

# Write transcript line count to lock (before forking) to prevent race between Stop and SessionEnd
# Storing the count enables re-save detection when a resumed session accumulates new work
if [ -n "$LOCK_FILE" ]; then
  echo "$TRANSCRIPT_LINES" > "$LOCK_FILE"
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
  --arg file_path "$FILE_PATH" \
  --arg base_name "$BASE_NAME" \
  --arg date_iso "$DATE_ISO" \
  --arg saved_at "$SAVED_AT" \
  --arg hook_input_json "$INPUT" \
  '{transcript_path: $transcript_path, cwd: $cwd, hook_event: $hook_event,
    session_id: $session_id, file_path: $file_path, base_name: $base_name,
    date_iso: $date_iso, saved_at: $saved_at,
    hook_input_json: $hook_input_json}' > "$WORK_FILE"

# Launch detached worker — survives parent exit/SIGHUP
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
nohup "$SCRIPT_DIR/llm-history-worker.sh" "$WORK_FILE" </dev/null >/dev/null 2>&1 &

log "DISPATCH: session=$SESSION_ID event=$HOOK_EVENT worker_pid=$! -> $FILE_PATH"

# Clean up old lock files (older than 2 days)
find "$LOCKDIR" -name "*.saved" -mtime +2 -delete 2>/dev/null || true

exit 0
