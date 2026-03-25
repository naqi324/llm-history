#!/usr/bin/env bash
# llm-history-worker.sh — Detached worker that generates and saves LLM history
# Launched by llm-history-save.sh via nohup; survives parent exit/SIGHUP.
# Reads all input from a temp work file (JSON) passed as $1.

set -euo pipefail
# NOTE: pipefail means ALL command substitutions with jq/grep pipelines
# must use || true — jq returns non-zero on any malformed JSONL line.

# Worker runs in its own process — independently unset CLAUDECODE
unset CLAUDECODE 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOGFILE="${LLM_HISTORY_WORKER_LOGFILE:-/tmp/llm-history-worker.log}"
CLAUDE_BIN="${LLM_HISTORY_CLAUDE_BIN:-claude}"
WORK_FILE="${1:?Usage: llm-history-worker.sh <work-file>}"
CONTEXT_HELPER="${LLM_HISTORY_CONTEXT_HELPER:-$SCRIPT_DIR/llm-history-context.py}"
CONTEXT_FILE=""
RENDER_MODE="${LLM_HISTORY_RENDER_MODE:-standard}"

mkdir -p "$(dirname "$LOGFILE")"

log() { echo "[$(date -Iseconds)] $*" >> "$LOGFILE" 2>/dev/null; }
cleanup() { rm -f "$WORK_FILE" "${CONTEXT_FILE:-}" 2>/dev/null; }
trap cleanup EXIT
trap 'log "ERROR: session=${SESSION_ID:-unknown} line=$LINENO"; exit 1' ERR

normalize_status() {
  printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'
}

parse_structured_summary() {
  local raw="$1"
  local line1 line2 line3 status_candidate

  TITLE=""
  TAGS_CSV=""
  STATUS=""
  SUMMARY_BODY=""

  [ -n "$raw" ] || return 1

  line1=$(printf '%s\n' "$raw" | sed -n '1p')
  line2=$(printf '%s\n' "$raw" | sed -n '2p')
  line3=$(printf '%s\n' "$raw" | sed -n '3p')

  case "$line1" in
    TITLE:*) TITLE=$(printf '%s' "$line1" | sed 's/^TITLE:[[:space:]]*//') ;;
    *) return 1 ;;
  esac

  case "$line2" in
    TAGS:*) TAGS_CSV=$(printf '%s' "$line2" | sed 's/^TAGS:[[:space:]]*//') ;;
    *) return 1 ;;
  esac

  case "$line3" in
    STATUS:*) status_candidate=$(printf '%s' "$line3" | sed 's/^STATUS:[[:space:]]*//') ;;
    *) return 1 ;;
  esac

  STATUS=$(normalize_status "$status_candidate")
  case "$STATUS" in
    completed|in-progress|blocked) ;;
    *) return 1 ;;
  esac

  SUMMARY_BODY=$(printf '%s\n' "$raw" | sed '1,3d')
  [ -n "$TITLE" ] || return 1
  [ -n "$TAGS_CSV" ] || return 1
  [ -n "$SUMMARY_BODY" ] || return 1

  return 0
}

is_generic_title() {
  local lowered
  lowered=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
  lowered=$(printf '%s' "$lowered" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')

  case "$lowered" in
    ""|*" session"|"$PROJECT_DIR"*|"${PROJECT_SLUG} session"|*"progress on session work"|auto-save|auto-save\ summary|session\ summary) return 0 ;;
    "~/"*"/ session"|"/"*"/ session") return 0 ;;
    *) return 1 ;;
  esac
}

has_only_generic_tags() {
  local tag lowered meaningful=0
  while IFS= read -r tag; do
    lowered=$(printf '%s' "$tag" | tr '[:upper:]' '[:lower:]' | sed 's/^ *//; s/ *$//')
    case "$lowered" in
      ""|auto-save|llm-history|session|session-context|session-preservation|workflow) ;;
      *) meaningful=1 ;;
    esac
  done < <(printf '%s' "${1:-}" | tr ',' '\n')

  [ "$meaningful" -eq 0 ]
}

summary_has_heading() {
  printf '%s\n' "$SUMMARY_BODY" | grep -Fx "## $1" >/dev/null
}

summary_has_numbered_steps() {
  awk '
    /^## Concrete Next Steps$/ { in_section=1; next }
    /^## / { in_section=0 }
    in_section && /^[0-9]+\./ { found=1 }
    END { exit(found ? 0 : 1) }
  ' <<EOF
$SUMMARY_BODY
EOF
}

contains_forbidden_language() {
  printf '%s\n' "$SUMMARY_BODY" | grep -Eiq \
    "could you clarify|what would you like to work on|what would you like me to do|please let me know what you'd like|tell me what you want to work on"
}

summary_mentions_required_facts() {
  local required_file required_check
  required_file="${REQUIRED_FILE_MENTION:-}"
  required_check="${REQUIRED_CHECK_MENTION:-}"

  if [ -n "$required_file" ]; then
    printf '%s\n' "$SUMMARY_BODY" | grep -F "$required_file" >/dev/null || return 1
  fi

  if [ -n "$required_check" ]; then
    printf '%s\n' "$SUMMARY_BODY" | grep -F "$required_check" >/dev/null || return 1
  fi

  return 0
}

validate_structured_summary() {
  local raw="$1"
  local tag_count

  VALIDATION_ERROR=""
  parse_structured_summary "$raw" || {
    VALIDATION_ERROR="missing required metadata"
    return 1
  }

  TITLE=$(printf '%s' "$TITLE" | head -c 100)
  tag_count=$(printf '%s' "$TAGS_CSV" | tr ',' '\n' | sed '/^[[:space:]]*$/d' | awk 'END { print NR + 0 }')
  if [ "$tag_count" -lt 3 ] || [ "$tag_count" -gt 5 ]; then
    VALIDATION_ERROR="expected 3-5 tags"
    return 1
  fi

  if is_generic_title "$TITLE"; then
    VALIDATION_ERROR="generic title"
    return 1
  fi

  if has_only_generic_tags "$TAGS_CSV"; then
    VALIDATION_ERROR="generic tags"
    return 1
  fi

  for heading in "Executive Summary" "Working State" "Files Changed" "Concrete Next Steps"; do
    if ! summary_has_heading "$heading"; then
      VALIDATION_ERROR="missing heading: $heading"
      return 1
    fi
  done

  if ! summary_has_numbered_steps; then
    VALIDATION_ERROR="missing numbered next steps"
    return 1
  fi

  if contains_forbidden_language; then
    VALIDATION_ERROR="forbidden conversational language"
    return 1
  fi

  if ! summary_mentions_required_facts; then
    VALIDATION_ERROR="missing grounded fact mention"
    return 1
  fi

  return 0
}

build_prompt_payload() {
  local session_facts repo_facts tool_facts derived_facts assistant_narrative

  session_facts=$(jq '{
    session_id: .session.session_id,
    session_name: .session.session_name,
    trigger: .session.trigger,
    project_dir: .session.project_dir,
    project_slug: .session.project_slug,
    last_user_ask: .session.last_user_ask,
    recent_user_asks: .session.recent_user_asks,
    assistant_milestones: .session.assistant_milestones
  }' "$CONTEXT_FILE")
  repo_facts=$(jq '.repo' "$CONTEXT_FILE")
  tool_facts=$(jq '.tools' "$CONTEXT_FILE")
  derived_facts=$(jq '{
    grounded_tags: .derived.grounded_tags,
    fallback_title: .derived.fallback_title,
    fallback_status: .derived.fallback_status,
    next_steps: .derived.next_steps
  }' "$CONTEXT_FILE")
  assistant_narrative=$(jq -r '.session.assistant_narrative' "$CONTEXT_FILE")

  printf '%s\n\nRules for this invocation:\n- Output only the requested handoff document.\n- Do not ask questions.\n- Do not add any prose before the TITLE/TAGS/STATUS lines.\n- Use only facts present in the labeled sections below.\n- If a fact is missing, say `unknown` instead of guessing.\n- Never use a path-only title or a `<project> session` title.\n- For nontrivial sessions, include `## Executive Summary`, `## Working State`, `## Files Changed`, and `## Concrete Next Steps`.\n- Never fall back to generic-only tags when grounded facts are available.\n\nBEGIN SESSION FACTS\n%s\nEND SESSION FACTS\n\nBEGIN REPO FACTS\n%s\nEND REPO FACTS\n\nBEGIN TOOL FACTS\n%s\nEND TOOL FACTS\n\nBEGIN DERIVED FACTS\n%s\nEND DERIVED FACTS\n\nBEGIN ASSISTANT NARRATIVE\n%s\nEND ASSISTANT NARRATIVE\n' \
    "$PROMPT_TEXT" \
    "$session_facts" \
    "$repo_facts" \
    "$tool_facts" \
    "$derived_facts" \
    "$assistant_narrative"
}

build_fallback_summary() {
  jq -r --arg render_note "$FALLBACK_RENDER_NOTE" '
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
    + "\n\n## Warnings\n\n"
    + bullets(
        (.derived.warning_lines + [
          $render_note
        ])
      )
  ' "$CONTEXT_FILE"
}

# Trim log when > 200 lines
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

# Fallback if saved_at missing (backward compat with pre-v2 dispatcher)
[ -z "$SAVED_AT" ] && SAVED_AT=$(date -Iseconds)

log "START session=$SESSION_ID event=$HOOK_EVENT"

# --- Generate summary via claude -p or deterministic grounded render ---

# Shorten home path for display
PROJECT_DIR="${CWD/#\/Users\/naqi.khan/~}"
MODEL_LABEL="auto-saved (sonnet)"
FALLBACK_RENDER_NOTE="- This handoff was rendered from grounded session facts after model output was rejected or unavailable."

# Build grounded context bundle from transcript + lightweight repo probing
CONTEXT_FILE=$(mktemp /tmp/llm-history-context-XXXXXX)
python3 "$CONTEXT_HELPER" "$WORK_FILE" > "$CONTEXT_FILE"

# Extract scalar fields in a single jq call
eval "$(jq -r '
  "SESSION_NAME=" + ((.session.session_name // "") | @sh),
  "PROJECT_SLUG=" + (.session.project_slug | @sh),
  "REQUIRED_FILE_MENTION=" + ((.derived.required_file_mentions[0] // "") | @sh),
  "REQUIRED_CHECK_MENTION=" + ((.derived.required_check_mentions[0] // "") | @sh),
  "FALLBACK_TITLE=" + (.derived.fallback_title | @sh),
  "FALLBACK_STATUS=" + (.derived.fallback_status | @sh),
  "FALLBACK_TAGS_CSV=" + ((.derived.grounded_tags | join(",")) | @sh)' "$CONTEXT_FILE")"
SUMMARY=""

if [ "$RENDER_MODE" = "session-end-sync" ]; then
  MODEL_LABEL="auto-saved (grounded deterministic)"
  FALLBACK_RENDER_NOTE="- This handoff was rendered directly from grounded session facts during SessionEnd to avoid nested Claude invocation."
  log "INFO: render_mode=$RENDER_MODE session=$SESSION_ID skipping claude -p"
else
  # Load prompt from external file with inline fallback
  PROMPT_FILE="$SCRIPT_DIR/../references/prompt.md"
  if [ -f "$PROMPT_FILE" ]; then
    PROMPT_TEXT=$(cat "$PROMPT_FILE")
  else
    log "WARN: prompt file missing ($PROMPT_FILE), using inline fallback"
    PROMPT_TEXT="You are generating a session handoff document for Claude Code session resumption.
Analyze the grounded session facts and produce ONLY markdown body content (no YAML frontmatter).

FIRST LINE: TITLE: <descriptive 5-10 word title>
SECOND LINE: TAGS: <3-5 comma-separated lowercase tags>
THIRD LINE: STATUS: <completed|in-progress|blocked>

Then sections: Executive Summary, Working State, Files Changed, Concrete Next Steps. Key Decisions, Failed Approaches, and Warnings are optional. Use only the provided facts; if a fact is missing, say unknown. Never ask clarifying questions. Under 300 lines."
  fi

  PROMPT_PAYLOAD=$(build_prompt_payload)

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
  SUMMARY=$(printf '%s' "$PROMPT_PAYLOAD" | run_with_timeout "$CLAUDE_BIN" -p \
    --model sonnet \
    --no-session-persistence \
    --disable-slash-commands \
    --strict-mcp-config \
    --tools "" 2>/dev/null) || true
fi

# --- Parse structured metadata from claude -p response ---

TITLE=""
TAGS_CSV=""
STATUS=""
SUMMARY_BODY=""

if [ -n "$SUMMARY" ]; then
  if validate_structured_summary "$SUMMARY"; then
    SUMMARY="$SUMMARY_BODY"
  else
    SUMMARY_PREVIEW=$(printf '%s\n' "$SUMMARY" | sed -n '1,3p' | tr '\n' '|' | cut -c1-200)
    log "WARN: invalid structured output from claude -p (${VALIDATION_ERROR:-unknown}; preview=${SUMMARY_PREVIEW:-empty})"
    SUMMARY=""
  fi
fi

# --- Fallback if claude -p failed or timed out ---

if [ -z "$SUMMARY" ]; then
  if [ "$RENDER_MODE" = "session-end-sync" ]; then
    log "INFO: building deterministic grounded SessionEnd handoff"
  else
    log "WARN: building deterministic fallback from grounded session facts"
  fi
  SUMMARY=$(build_fallback_summary)
  TITLE="$FALLBACK_TITLE"
  STATUS="$FALLBACK_STATUS"
  TAGS_CSV="$FALLBACK_TAGS_CSV"
fi

# --- Validate and default metadata ---

case "$STATUS" in completed|in-progress|blocked) ;; *) STATUS="in-progress" ;; esac
[ -z "$TITLE" ] && TITLE="$FALLBACK_TITLE"

# Convert tags CSV to YAML list
if [ -n "$TAGS_CSV" ]; then
  TAGS_YAML=$(echo "$TAGS_CSV" | tr ',' '\n' | sed 's/^ *//; s/ *$//' | sed 's/^/  - /')
else
  TAGS_YAML=$(jq -r '.derived.grounded_tags | map("  - " + .) | join("\n")' "$CONTEXT_FILE")
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

# Append H1 title and body using printf to avoid shell expansion in SUMMARY
printf '# %s\n\n%s\n' "$TITLE" "$SUMMARY" >> "$FILE_PATH"

log "DONE session=$SESSION_ID -> $FILE_PATH"

exit 0
