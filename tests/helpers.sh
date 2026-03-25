#!/usr/bin/env bash
# Shared test helpers — sourced by all test harnesses.

TEST_DIRS=()

cleanup() {
  local dir
  for dir in "${TEST_DIRS[@]:-}"; do
    rm -rf "$dir"
  done
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file_exists() {
  [ -f "$1" ] || fail "expected file to exist: $1"
}

assert_not_exists() {
  [ ! -e "$1" ] || fail "expected path to be absent: $1"
}

assert_contains() {
  local path="$1"
  local needle="$2"
  grep -F "$needle" "$path" >/dev/null || fail "expected '$needle' in $path"
}

assert_jq() {
  local filter="$1"
  local path="$2"
  jq -e "$filter" "$path" >/dev/null || fail "jq assertion failed: $filter on $path"
}

copy_transcript_fixture() {
  local target="$1"
  cp "${FIXTURES_DIR:?FIXTURES_DIR must be set}/transcript-base.jsonl" "$target"
}
