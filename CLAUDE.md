# llm-history

Session context preservation skill for Claude Code. Saves structured markdown files to the Obsidian vault for seamless session resumption.

## Structure

- `SKILL.md` — Skill definition (manual `/llm-history` invocation)
- `AGENTS.md` — Codex CLI/Desktop instructions
- `scripts/llm-history-save.sh` — Hook dispatcher (fast guards + fork worker)
- `scripts/llm-history-worker.sh` — Detached worker (grounded render + optional claude -p enrichment)
- `scripts/llm-history-context.py` — Grounded context extraction from transcript facts + lightweight repo probes
- `scripts/exit-orchestrator.sh` — Authoritative `/exit` pipeline (git phase, then history phase)
- `scripts/exit-audit.sh` — Summarizes recent orchestrated exit outcomes and flags missing history/pipeline completion
- `references/template.md` — Output format documentation
- `references/prompt.md` — Externalized claude -p prompt
- `tests/smoke.sh` — Temp-dir regression harness for dispatcher + worker behavior
- `tests/exit-orchestrator-smoke.sh` — Temp-dir regression harness for ordered SessionEnd exit behavior
- `tests/resume-readiness.sh` — Quality harness for grounded handoff usefulness across multiple session shapes
- `tests/check_resume_readiness.py` — Rubric-based evaluator for generated handoffs
- `tests/fixtures/` — Transcript fixtures and stub Claude responses for smoke tests
- `tests/golden/` — Normalized expected markdown outputs used by the smoke test
- `tests/logs/` — Generated JSON quality reports (ignored except for `.gitkeep`)

## Output Directory

`/Users/naqi.khan/Documents/Obsidian/LLM History/`

## Hooks

Configured in `~/.claude/settings.json`:
- `PreCompact` hook — auto-saves when context window triggers compaction (async)
- `SessionEnd` hook — runs `scripts/exit-orchestrator.sh` synchronously as the authoritative `/exit` path

## Exit Orchestration

- `/exit` now runs one authoritative synchronous pipeline:
  - git phase via `/Users/naqi.khan/git/system/CLAUDE-md/.claude/hooks/auto-git-commit.sh`
  - history phase via `scripts/llm-history-save.sh` with `LLM_HISTORY_SYNC=1` and `LLM_HISTORY_RENDER_MODE=session-end-sync`
- History starts only after the git phase exits.
- `SessionEnd` history renders directly from the grounded context bundle and never calls `claude -p`.
- Richer model-backed summarization is preserved for non-exit flows such as `PreCompact`.
- The shared orchestrator log defaults to `/tmp/claude-exit-orchestrator.log`.
- Each phase records `session_id`, `cwd`, phase name, result, detail, and duration.
- Pipeline summaries record `git_result`, `history_result`, `history_render_mode`, and `overall`.
- Use `scripts/exit-audit.sh` to inspect the latest orchestrated exits.

## Current Save Semantics

- First save for a session writes immediately.
- If a vault file already exists for the same `session_id` but the lock is missing or invalid, the dispatcher bootstraps a fresh lock and skips once.
- Valid key/value locks re-save only when both conditions are true:
  - lock age is at least 120 seconds
  - transcript growth is at least 5 JSONL lines
- Legacy numeric lock files are still accepted as a delta-only fallback during migration.
- Empty or malformed lock files are treated as invalid and re-bootstrapped instead of blocking future saves forever.

## Worker Validation

- The worker first builds a normalized grounded context bundle from transcript facts, tool calls/results, file-history snapshots, and lightweight repo probes.
- In standard mode, the worker sends Claude one explicit prompt payload containing labeled `SESSION FACTS`, `REPO FACTS`, `TOOL FACTS`, `DERIVED FACTS`, and `ASSISTANT NARRATIVE` sections.
- In `session-end-sync` mode, the worker skips `claude -p` entirely and writes the deterministic grounded handoff directly.
- Claude output is only accepted when the first three lines are exactly `TITLE:`, `TAGS:`, and `STATUS:`.
- `STATUS` must normalize to `completed`, `in-progress`, or `blocked`.
- Output is rejected when it is still low-value after parsing, including generic titles/tags, missing required sections, missing numbered next steps, forbidden clarifying language, or missing grounded fact mentions.
- If validation fails, the worker logs a warning and writes a deterministic grounded fallback instead of saving raw conversational output.

## Test Overrides

Optional env overrides for safe local testing:

- `LLM_HISTORY_VAULT_DIR`
- `LLM_HISTORY_LOCK_DIR`
- `LLM_HISTORY_HOOK_LOGFILE`
- `LLM_HISTORY_WORKER_LOGFILE`
- `LLM_HISTORY_CLAUDE_BIN`
- `LLM_HISTORY_RENDER_MODE`
- `CLAUDE_EXIT_LOGFILE`
- `CLAUDE_EXIT_GIT_SCRIPT`
- `CLAUDE_EXIT_HISTORY_SCRIPT`
- `CLAUDE_EXIT_HISTORY_RENDER_MODE`
- `AUTO_GIT_LOGFILE`
- `LLM_HISTORY_CONTEXT_HELPER`

Run the regression harness with:

```bash
tests/smoke.sh
tests/exit-orchestrator-smoke.sh
tests/resume-readiness.sh
```

The harness uses temp directories and a stub Claude binary, so it never touches the live Obsidian vault.

## Distribution

| Surface | Read | Write | Mechanism |
|---------|------|-------|-----------|
| Claude Code CLI | QMD MCP | Auto (hooks) + manual | `~/.claude/skills/llm-history` symlink |
| Claude Desktop | QMD MCP | N/A | QMD indexes Obsidian vault |
| Codex CLI | QMD MCP | Manual only | `~/.agents/skills/llm-history` symlink |
| Codex Desktop | QMD MCP | Manual only | Same as Codex CLI |
