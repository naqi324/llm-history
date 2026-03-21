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
- Date: 2026-03-21
- Work state: `SessionEnd` now stays git-first/history-last but renders history deterministically from grounded facts instead of invoking `claude -p` during shutdown, while non-exit flows keep the richer model-backed worker path.
- Decisions:
- The old parallel Claude `Stop` hooks for auto-git and `llm-history` were removed from `~/.claude/settings.json`.
- `SessionEnd` is now the single authoritative exit path and uses a 240-second timeout.
- `scripts/llm-history-save.sh` supports `LLM_HISTORY_SYNC=1` for synchronous SessionEnd execution while keeping async worker dispatch for non-exit flows.
- `scripts/exit-orchestrator.sh` now passes `LLM_HISTORY_RENDER_MODE=session-end-sync` so exit-time history never nests a Claude subprocess during shutdown.
- Auto-git and history scripts both write structured result files so the orchestrator can log `success`, `skip-*`, and `error` outcomes per phase.
- `scripts/exit-audit.sh` now reports an `EXIT_SAFE` metric and flags any exit run missing `history` or `pipeline done`.
- `tests/exit-orchestrator-smoke.sh` now hard-fails if `SessionEnd` tries to call `claude -p`, and covers trivial, missing-transcript, dedup, git-failure, and audit safety cases.
- Added `scripts/llm-history-context.py` so the worker can extract grounded session/repo/tool facts instead of summarizing assistant prose alone.
- The worker now rejects low-value model output (generic title/tags, missing sections, vague next steps, clarifying language, missing grounded facts) and renders a deterministic grounded fallback instead.
- Added `tests/resume-readiness.sh`, `tests/check_resume_readiness.py`, and a five-scenario fixture corpus to score groundedness, specificity, and resumability.
- Next steps:
- If a real `/exit` still looks suspicious, inspect `/tmp/claude-exit-orchestrator.log` first or run `scripts/exit-audit.sh` and look for `EXIT_SAFE != safe`.
- Keep `tests/smoke.sh`, `tests/resume-readiness.sh`, and `tests/exit-orchestrator-smoke.sh` in the verification loop for future hook/prompt changes.
