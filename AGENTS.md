# llm-history (Codex)

Session context preservation for Codex CLI. Saves structured markdown to the Obsidian vault at `/Users/naqi.khan/Documents/Obsidian/LLM History/`.

## Manual Usage

Read SKILL.md and follow the 6-step workflow. The Write tool, Bash, and Glob tools are available in Codex for file operations.

Key steps:
1. Generate filename: `YYMMDD-<project>.md` (project from CWD basename, kebab-case)
2. Gather session context: executive summary, key decisions, in-progress work, files, next steps
3. Write YAML frontmatter (date, saved_at, title, model, project, session_id, status, trigger, tags) + markdown body
4. Save to `/Users/naqi.khan/Documents/Obsidian/LLM History/`

## Reading History

Use QMD MCP to search existing history files:
- `mcp__qmd__query` with collection "obsidian", intent "find session history for <topic>"
- `mcp__qmd__get` to read full file content by path

## Limitations

Codex CLI has no hook system. Auto-save on session exit is NOT supported. Use manual save before ending important sessions.

## Session Context
- Date: 2026-04-23
- Work state: Rendering is deterministic in every path (SessionEnd, PreCompact, manual). The worker builds the handoff directly from the grounded context bundle produced by `scripts/llm-history-context.py`; no nested `claude -p` call.
- Key properties:
  - `SessionEnd` is the single authoritative exit path via `scripts/exit-orchestrator.sh` (git phase first, history phase second, 240-second budget).
  - `scripts/llm-history-save.sh` supports `LLM_HISTORY_SYNC=1` for synchronous SessionEnd execution while keeping async worker dispatch for non-exit flows.
  - `scripts/exit-audit.sh` reports an `EXIT_SAFE` metric and flags any exit run missing `history` or `pipeline done`.
  - `scripts/llm-history-context.py` extracts grounded session/repo/tool facts from the transcript and probes the repo.
- Verification:
  - `tests/smoke.sh` covers dispatcher + worker plumbing, dedup/re-save/lock behavior, and the deterministic render output against goldens.
  - `tests/resume-readiness.sh` runs the worker across five fixture transcripts and scores output with the resume-readiness rubric.
  - `tests/exit-orchestrator-smoke.sh` covers ordered phase execution, git-failure isolation, audit reporting, and asserts the worker never shells out to `claude`.
- If a real `/exit` looks suspicious, inspect `/tmp/claude-exit-orchestrator.log` first or run `scripts/exit-audit.sh` and look for `EXIT_SAFE != safe`.
