# llm-history

Session context preservation skill for Claude Code. Saves structured markdown files to the Obsidian vault for seamless session resumption.

## Structure

- `SKILL.md` — Skill definition (manual `/llm-history` invocation)
- `AGENTS.md` — Codex CLI/Desktop instructions
- `scripts/llm-history-save.sh` — Hook dispatcher (fast guards + fork worker)
- `scripts/llm-history-worker.sh` — Detached worker (deterministic grounded render; no model calls)
- `scripts/llm-history-context.py` — Grounded context extraction from transcript facts + lightweight repo probes
- `scripts/exit-orchestrator.sh` — Authoritative `/exit` pipeline (git phase, then history phase)
- `scripts/exit-audit.sh` — Summarizes recent orchestrated exit outcomes and flags missing history/pipeline completion
- `scripts/llm-history-audit.sh` — Scores recent vault files against the resume-readiness rubric; used as the Phase 1 -> Phase 2 gate (fail rate must be <= 10% before starting Phase 2)
- `references/template.md` — Output format documentation
- `tests/smoke.sh` — Temp-dir regression harness for dispatcher + worker behavior
- `tests/exit-orchestrator-smoke.sh` — Temp-dir regression harness for ordered SessionEnd exit behavior
- `tests/resume-readiness.sh` — Quality harness for grounded handoff usefulness across multiple session shapes
- `tests/check_resume_readiness.py` — Rubric-based evaluator for generated handoffs
- `tests/fixtures/` — Transcript fixtures for smoke and quality tests
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
- History is always rendered directly from the grounded context bundle. There is no nested `claude -p` call in any path (SessionEnd, PreCompact, or manual).
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

## Worker Rendering

- The worker builds a normalized grounded context bundle from transcript facts, tool calls/results, file-history snapshots, and lightweight repo probes.
- Rendering is deterministic end-to-end: frontmatter and the resume-packet body are written directly from the bundle. No `claude -p` call.
- The body is optimized for continuation: Resume Snapshot, Task Ledger, Workspace Truth, Decisions And Rationale, Validation Evidence, Risks/Blockers/Unknowns, and Do Not Redo.
- `STATUS` is `completed`, `in-progress`, or `blocked` (derived from failure signals).
- `RENDER_MODE=session-end-sync` is preserved as a log signal for the orchestrator but no longer branches rendering logic.

## Test Overrides

Optional env overrides for safe local testing:

- `LLM_HISTORY_VAULT_DIR`
- `LLM_HISTORY_LOCK_DIR`
- `LLM_HISTORY_HOOK_LOGFILE`
- `LLM_HISTORY_WORKER_LOGFILE`
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
| Claude Code CLI | Built-in QMD MCP (`qmd mcp`) | Auto (hooks) + manual | Claude compatibility skill path |
| Claude Desktop | Built-in QMD MCP (`qmd mcp`) | N/A | QMD indexes Obsidian vault |
| Codex CLI | Built-in QMD MCP or global `qmd` CLI fallback | Manual only | `~/.agents/skills/llm-history` |
| Codex Desktop | Built-in QMD MCP or global `qmd` CLI fallback | Manual only | Same as Codex CLI |

QMD's canonical skill path is `~/.agents/skills/qmd/SKILL.md`. Do not call repo-local QMD checkouts, `qmd/dist/cli/qmd.js`, or retired `qmd-setup` paths.
