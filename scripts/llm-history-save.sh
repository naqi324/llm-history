#!/usr/bin/env bash
# llm-history-save.sh — Auto-save session context to Obsidian vault
# Called by PreCompact hooks directly and by the exit orchestrator for SessionEnd.
# Receives hook JSON on stdin with session_id, transcript_path, cwd, etc.
# This is the fast dispatcher — it runs guards and normally forks a detached worker
# for the slow claude -p summarization. When LLM_HISTORY_SYNC=1, it runs inline.

set -euo pipefail
# NOTE: pipefail means ALL command substitutions with jq/grep pipelines
# must use || true — jq returns non-zero on any malformed JSONL line.

LOGFILE="${LLM_HISTORY_HOOK_LOGFILE:-/tmp/llm-history-hook.log}"
VAULT_DIR="${LLM_HISTORY_VAULT_DIR:-/Users/naqi.khan/Documents/Obsidian/LLM History}"
LOCKDIR="${LLM_HISTORY_LOCK_DIR:-/tmp/llm-history-locks}"
RESULT_FILE="${LLM_HISTORY_RESULT_FILE:-}"
SYNC_MODE="${LLM_HISTORY_SYNC:-0}"
RENDER_MODE="${LLM_HISTORY_RENDER_MODE:-standard}"
MIN_RESAVE_SECONDS=120
MIN_RESAVE_LINE_DELTA=5

mkdir -p "$(dirname "$LOGFILE")"

log() { echo "[$(date -Iseconds)] $*" >> "$LOGFILE" 2>/dev/null; }
write_result() {
  [ -n "$RESULT_FILE" ] || return 0
  cat > "$RESULT_FILE" <<EOF
result=$1
detail=${2:-}
file_path=${3:-}
session_id=${SESSION_ID:-}
hook_event=${HOOK_EVENT:-}
EOF
}
finish() {
  write_result "$1" "${2:-}" "${3:-}"
  exit "${4:-0}"
}
trap 'log "ERROR at line $LINENO (session=${SESSION_ID:-unknown})"; write_result error trap ""; exit 1' ERR

is_integer() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

read_lock_file() {
  local path="$1"

  LOCK_STATE="missing"
  LOCK_SAVED_AT_EPOCH=""
  LOCK_TRANSCRIPT_LINES=""

  [ -f "$path" ] || return 0

  if [ ! -s "$path" ]; then
    LOCK_STATE="invalid"
    return 0
  fi

  local compact
  compact=$(tr -d '[:space:]' < "$path" 2>/dev/null || true)
  if [ -z "$compact" ]; then
    LOCK_STATE="invalid"
    return 0
  fi

  if is_integer "$compact"; then
    LOCK_STATE="legacy_numeric"
    LOCK_TRANSCRIPT_LINES="$compact"
    return 0
  fi

  while IFS='=' read -r key value || [ -n "$key" ]; do
    value=$(printf '%s' "$value" | tr -d '[:space:]')
    case "$key" in
      saved_at_epoch) LOCK_SAVED_AT_EPOCH="$value" ;;
      transcript_lines) LOCK_TRANSCRIPT_LINES="$value" ;;
    esac
  done < "$path"

  if is_integer "$LOCK_SAVED_AT_EPOCH" && is_integer "$LOCK_TRANSCRIPT_LINES"; then
    LOCK_STATE="valid"
  else
    LOCK_STATE="invalid"
    LOCK_SAVED_AT_EPOCH=""
    LOCK_TRANSCRIPT_LINES=""
  fi
}

write_lock_file() {
  local path="$1"
  local saved_at_epoch="$2"
  local transcript_lines="$3"

  printf 'saved_at_epoch=%s\ntranscript_lines=%s\n' \
    "$saved_at_epoch" "$transcript_lines" > "$path"
}

cleanup_stale_artifacts() {
  find /tmp -name "llm-history-work-*" -mtime +1 -delete 2>/dev/null || true
  [ -d "$LOCKDIR" ] && find "$LOCKDIR" -name "*.saved" -mtime +2 -delete 2>/dev/null || true
}

# Trim log when > 500 lines
if [ -f "$LOGFILE" ] && [ "$(wc -l < "$LOGFILE" | tr -d ' ')" -gt 500 ]; then
  tail -100 "$LOGFILE" > "${LOGFILE}.tmp" && mv "${LOGFILE}.tmp" "$LOGFILE"
fi

# Read hook input from stdin
INPUT=$(cat)
log "START input_length=${#INPUT}"

# Parse fields from hook JSON (single jq call)
eval "$(echo "$INPUT" | jq -r '
  "SESSION_ID=" + ((.session_id // "") | @sh),
  "TRANSCRIPT_PATH=" + ((.transcript_path // "") | @sh),
  "CWD=" + ((.cwd // "") | @sh),
  "HOOK_EVENT=" + ((.hook_event_name // "") | @sh),
  "STOP_HOOK_ACTIVE=" + ((.stop_hook_active // false | tostring) | @sh),
  "TRIGGER=" + ((.trigger // "") | @sh)')"

# --- Guards ---

# Guard 1: Prevent infinite loops when Stop hook triggers Claude continuation
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
  log "SKIP: stop_hook_active=true session=$SESSION_ID"
  finish "skip-stop-hook-active" "" "" 0
fi

# Guard 2: For PreCompact, only trigger on automatic compaction (not manual /compact)
if [ "$HOOK_EVENT" = "PreCompact" ]; then
  if [ "$TRIGGER" != "auto" ]; then
    log "SKIP: PreCompact manual trigger session=$SESSION_ID"
    finish "skip-precompact-manual" "" "" 0
  fi
fi

# Guard 3: Transcript must exist and be readable
if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then
  log "SKIP: transcript missing or unreadable ($TRANSCRIPT_PATH) session=$SESSION_ID"
  finish "skip-missing-transcript" "$TRANSCRIPT_PATH" "" 0
fi

# Guard 4: Skip trivial sessions (fewer than 10 lines)
TRANSCRIPT_LINES=$(wc -l < "$TRANSCRIPT_PATH" | tr -d ' ')
if [ "$TRANSCRIPT_LINES" -lt 10 ]; then
  log "SKIP: transcript too short ($TRANSCRIPT_LINES lines) session=$SESSION_ID"
  finish "skip-trivial" "$TRANSCRIPT_LINES-lines" "" 0
fi

# Guard 5: Unified session deduplication
# Handles three cases:
# (a) First save for this session → proceed
# (b) Existing vault file but missing/invalid lock → bootstrap lock and skip once
# (c) Valid lock → re-save only when both age and transcript growth exceed thresholds
mkdir -p "$LOCKDIR"
LOCK_FILE=""
CURRENT_EPOCH=$(date +%s)
if [ -n "$SESSION_ID" ]; then
  LOCK_FILE="$LOCKDIR/${SESSION_ID}-save.saved"
  read_lock_file "$LOCK_FILE"

  if [ "$LOCK_STATE" = "valid" ] || [ "$LOCK_STATE" = "legacy_numeric" ]; then
    PREV_LINES="$LOCK_TRANSCRIPT_LINES"
    if [ "$TRANSCRIPT_LINES" -gt "$PREV_LINES" ]; then
      LINE_DELTA=$((TRANSCRIPT_LINES - PREV_LINES))
    else
      LINE_DELTA=0
    fi

    if [ "$LOCK_STATE" = "valid" ]; then
      LOCK_AGE=$((CURRENT_EPOCH - LOCK_SAVED_AT_EPOCH))
      if [ "$LOCK_AGE" -lt 0 ]; then
        LOCK_AGE=0
      fi
      if [ "$LOCK_AGE" -ge "$MIN_RESAVE_SECONDS" ] && [ "$LINE_DELTA" -ge "$MIN_RESAVE_LINE_DELTA" ]; then
        log "RESAVE: resave criteria met (age=${LOCK_AGE}s delta=$LINE_DELTA prev=$PREV_LINES now=$TRANSCRIPT_LINES) session=$SESSION_ID"
      else
        log "SKIP: resave criteria not met (age=${LOCK_AGE}s delta=$LINE_DELTA prev=$PREV_LINES now=$TRANSCRIPT_LINES) session=$SESSION_ID"
        finish "skip-dedup" "age=${LOCK_AGE}s delta=$LINE_DELTA" "" 0
      fi
    else
      if [ "$LINE_DELTA" -ge "$MIN_RESAVE_LINE_DELTA" ]; then
        log "RESAVE: legacy lock satisfied delta-only fallback (age=unknown delta=$LINE_DELTA prev=$PREV_LINES now=$TRANSCRIPT_LINES) session=$SESSION_ID"
      else
        log "SKIP: legacy lock resave criteria not met (age=unknown delta=$LINE_DELTA prev=$PREV_LINES now=$TRANSCRIPT_LINES) session=$SESSION_ID"
        finish "skip-dedup" "age=unknown delta=$LINE_DELTA" "" 0
      fi
    fi
  else
    EXISTING=$(grep -rl "session_id: ${SESSION_ID}" "$VAULT_DIR" 2>/dev/null | head -1) || true
    if [ -n "$EXISTING" ]; then
      write_lock_file "$LOCK_FILE" "$CURRENT_EPOCH" "$TRANSCRIPT_LINES"
      log "SKIP: existing vault file with ${LOCK_STATE} lock; bootstrapped lock (lines=$TRANSCRIPT_LINES) session=$SESSION_ID"
      finish "skip-dedup" "bootstrapped-${LOCK_STATE}" "" 0
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

# Write the new-format lock before forking to prevent Stop/SessionEnd duplicates.
LOCK_FILE_PREVIOUS_CONTENT=""
LOCK_FILE_PREVIOUS_EXISTS="false"
if [ -n "$LOCK_FILE" ]; then
  if [ -f "$LOCK_FILE" ]; then
    LOCK_FILE_PREVIOUS_EXISTS="true"
    LOCK_FILE_PREVIOUS_CONTENT=$(cat "$LOCK_FILE")
  fi
  write_lock_file "$LOCK_FILE" "$CURRENT_EPOCH" "$TRANSCRIPT_LINES"
fi

# Clean up stale temp files from crashed workers (older than 1 day)
cleanup_stale_artifacts

# Write all collected data to a temp file for the worker
WORK_FILE=$(mktemp /tmp/llm-history-work-XXXXXX)
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
if [ "$SYNC_MODE" = "1" ]; then
  if "$SCRIPT_DIR/llm-history-worker.sh" "$WORK_FILE"; then
    SYNC_DETAIL="sync"
    if [ "$RENDER_MODE" != "standard" ]; then
      SYNC_DETAIL="sync-${RENDER_MODE}"
    fi
    log "DONE: session=$SESSION_ID event=$HOOK_EVENT sync=1 render_mode=$RENDER_MODE -> $FILE_PATH"
    finish "success" "$SYNC_DETAIL" "$FILE_PATH" 0
  fi
  if [ -n "$LOCK_FILE" ]; then
    if [ "$LOCK_FILE_PREVIOUS_EXISTS" = "true" ]; then
      printf '%s\n' "$LOCK_FILE_PREVIOUS_CONTENT" > "$LOCK_FILE"
    else
      rm -f "$LOCK_FILE"
    fi
  fi
  finish "error" "worker-failed" "$FILE_PATH" 1
else
  nohup "$SCRIPT_DIR/llm-history-worker.sh" "$WORK_FILE" </dev/null >/dev/null 2>&1 &
  log "DISPATCH: session=$SESSION_ID event=$HOOK_EVENT worker_pid=$! -> $FILE_PATH"
  finish "success-dispatched" "async" "$FILE_PATH" 0
fi
