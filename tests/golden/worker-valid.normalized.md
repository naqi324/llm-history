---
date: <DATE>
saved_at: <SAVED_AT>
title: 'Stabilize llm-history resave behavior'
model: auto-saved (sonnet)
project: ~/git/skills/llm-history
session_id: <SESSION_ID>
session_name: fixture-session
status: in-progress
trigger: Stop
tags:
  - llm-history
  - resave
  - validation
  - testing
---

# Stabilize llm-history resave behavior


## Executive Summary

Hardened the llm-history hooks so resumed sessions re-save on practical thresholds and malformed model output no longer lands in the vault. The dispatcher now tracks lock age and transcript growth, and the worker validates structured output before accepting it. The remaining work is running the smoke harness and reviewing the saved markdown shape.

## Key Decisions

- **What was chosen**: Combined lock age and line delta thresholds for resumed-session re-saves.
- **What was rejected**: A line-count-only threshold.
- **Why**: The old +50-line rule delayed legitimate re-saves for normal sessions.
- **Failure mode avoided**: Small but meaningful resumed sessions no longer disappear.

## Working State

The dispatcher and worker are updated, and the save path should now either emit a structured handoff or fall back locally. Hook wiring is unchanged; verification still depends on the smoke harness and a manual temp-dir dry run.

## Files Changed

- `scripts/llm-history-save.sh` - Migrates locks to key/value format, preserves legacy lock compatibility, and logs age/delta decisions.
- `scripts/llm-history-worker.sh` - Packages the prompt with a delimited transcript block and rejects malformed model output.

## Concrete Next Steps

1. Run `tests/smoke.sh`.
2. Review the normalized markdown outputs against the golden files.
3. If needed, run one manual dry run against temp directories only.

## Failed Approaches

- Relying on any non-empty Claude response allowed conversational replies to be saved as history files.

## Warnings

- Legacy numeric lock files still work, but empty lock files are re-bootstrapped on the next save.
