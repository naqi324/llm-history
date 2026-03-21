#!/usr/bin/env bash

set -euo pipefail

cat >/dev/null

if [ -n "${AUTO_GIT_RESULT_FILE:-}" ]; then
  cat > "$AUTO_GIT_RESULT_FILE" <<'EOF'
result=error
detail=synthetic-failure
repo_root=
branch=
EOF
fi

exit 1
