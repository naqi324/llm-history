#!/usr/bin/env bash

set -euo pipefail

payload=$(cat)

if [ -n "${LLM_HISTORY_TEST_CAPTURE_STDIN:-}" ]; then
  printf '%s' "$payload" > "$LLM_HISTORY_TEST_CAPTURE_STDIN"
fi

cat "${LLM_HISTORY_TEST_CLAUDE_RESPONSE_FILE:?LLM_HISTORY_TEST_CLAUDE_RESPONSE_FILE is required}"
