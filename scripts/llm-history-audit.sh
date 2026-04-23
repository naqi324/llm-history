#!/usr/bin/env bash
# llm-history-audit.sh — score recent vault files against the Phase 1 rubric.
#
# Usage:
#   scripts/llm-history-audit.sh            # last 14 days, terminal report
#   scripts/llm-history-audit.sh 30         # last 30 days
#   scripts/llm-history-audit.sh 14 json    # machine-readable output
#
# This script is the enforceable gate from Phase 1 -> Phase 2: if the failure
# rate across recent auto-saved handoffs exits > 10%, iterate Phase 1 before
# starting Phase 2. Run it every few days (or wire it into a cron).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECKER="$SCRIPT_DIR/../tests/check_resume_readiness.py"
VAULT_DIR="${LLM_HISTORY_VAULT_DIR:-/Users/naqi.khan/Documents/Obsidian/LLM History}"
DAYS="${1:-14}"
FORMAT="${2:-text}"

if [ ! -d "$VAULT_DIR" ]; then
  printf 'error: vault dir does not exist: %s\n' "$VAULT_DIR" >&2
  exit 2
fi

if [ ! -x "$CHECKER" ] && ! command -v python3 >/dev/null; then
  printf 'error: python3 not available\n' >&2
  exit 2
fi

# macOS + GNU find differ on -mtime semantics; stick to -mtime -<days>.
MD_FILES=$(find "$VAULT_DIR" -maxdepth 1 -type f -name '*.md' -mtime -"$DAYS" | sort)

if [ -z "$MD_FILES" ]; then
  if [ "$FORMAT" = "json" ]; then
    printf '{"days":%s,"total":0,"passed":0,"failed":0,"failure_rate":null,"failures":[]}\n' "$DAYS"
  else
    printf 'No vault files modified in the last %s days. Nothing to score.\n' "$DAYS"
  fi
  exit 0
fi

total=0
passed=0
failed=0
failure_lines=()
failure_json=()

while IFS= read -r path; do
  [ -z "$path" ] && continue
  total=$((total + 1))
  empty_bundle="$(mktemp /tmp/llm-history-audit-bundle-XXXXXX)"
  printf '%s' '{"derived":{"required_file_mentions":[],"required_check_mentions":[]},"repo":{"is_git":false,"branch":""}}' \
    > "$empty_bundle"
  if report=$(python3 "$CHECKER" "$path" "$empty_bundle" "audit-$(basename "$path")" 2>/dev/null); then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    failures=$(printf '%s' "$report" | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin).get("failures", [])))')
    failure_lines+=("$(basename "$path")	$failures")
    failure_json+=("$report")
  fi
  rm -f "$empty_bundle"
done <<<"$MD_FILES"

rate=$(python3 -c "print(f'{($failed/$total*100):.1f}' if $total else '0.0')")

if [ "$FORMAT" = "json" ]; then
  AUDIT_DAYS="$DAYS" python3 - "$total" "$passed" "$failed" "$rate" "${failure_json[@]:-}" <<'PY'
import json
import os
import sys
total, passed, failed, rate, *reports = sys.argv[1:]
parsed = [json.loads(r) for r in reports if r]
print(json.dumps({
    "days": int(os.environ.get("AUDIT_DAYS", 0)),
    "total": int(total),
    "passed": int(passed),
    "failed": int(failed),
    "failure_rate_percent": float(rate),
    "failures": parsed,
}, indent=2))
PY
  exit 0
fi

printf 'llm-history audit — last %s days\n' "$DAYS"
printf 'Vault: %s\n' "$VAULT_DIR"
printf 'Scored: %s files  |  passed: %s  |  failed: %s  |  failure rate: %s%%\n' \
  "$total" "$passed" "$failed" "$rate"

if [ ${#failure_lines[@]} -gt 0 ]; then
  printf '\nFILE\tFAILURES\n'
  for line in "${failure_lines[@]}"; do
    printf '%s\n' "$line"
  done
fi

if awk -v r="$rate" 'BEGIN {exit (r+0 <= 10.0) ? 0 : 1}'; then
  printf '\nGate: PASS (<= 10%% failure rate). Phase 2 work may proceed.\n'
  exit 0
else
  printf '\nGate: FAIL (> 10%% failure rate). Iterate Phase 1 before Phase 2.\n'
  exit 1
fi
