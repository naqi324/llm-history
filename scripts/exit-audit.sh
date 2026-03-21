#!/usr/bin/env bash

set -euo pipefail

LOGFILE="${CLAUDE_EXIT_LOGFILE:-/tmp/claude-exit-orchestrator.log}"
COUNT="${1:-20}"

if [ ! -f "$LOGFILE" ]; then
  echo "No exit orchestrator log found at $LOGFILE"
  exit 0
fi

python3 - "$LOGFILE" "$COUNT" <<'PY'
import json
import sys

path = sys.argv[1]
count = int(sys.argv[2])
runs = []
current = None

with open(path, "r", encoding="utf-8") as handle:
    for raw_line in handle:
        line = raw_line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue

        phase = entry.get("phase")
        if phase == "pipeline" and entry.get("state") == "start":
            current = {
                "timestamp": entry.get("timestamp", ""),
                "session_id": entry.get("session_id", ""),
                "cwd": entry.get("cwd", ""),
                "git": "",
                "history": "",
                "overall": "",
                "exit_safe": "missing-history-or-done",
            }
            runs.append(current)
            continue

        if current is None:
            continue

        if phase == "git":
            current["git"] = entry.get("result", "")
        elif phase == "history":
            current["history"] = entry.get("result", "")
        elif phase == "pipeline" and entry.get("state") == "done":
            current["overall"] = entry.get("overall", "")
            if current.get("history"):
                current["exit_safe"] = "safe"

print("TIMESTAMP\tSESSION\tGIT\tHISTORY\tOVERALL\tEXIT_SAFE\tCWD")
for run in runs[-count:]:
    print(
        "\t".join(
            [
                run.get("timestamp", ""),
                run.get("session_id", ""),
                run.get("git", ""),
                run.get("history", ""),
                run.get("overall", ""),
                run.get("exit_safe", ""),
                run.get("cwd", ""),
            ]
        )
    )
PY
