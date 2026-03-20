# llm-history

Session context preservation skill for Claude Code. Saves structured markdown files to the Obsidian vault for seamless session resumption.

## Structure

- `SKILL.md` — Skill definition (manual `/llm-history` invocation)
- `AGENTS.md` — Codex CLI/Desktop instructions
- `scripts/llm-history-save.sh` — Hook dispatcher (fast guards + fork worker)
- `scripts/llm-history-worker.sh` — Detached worker (claude -p summarization + file write)
- `references/template.md` — Output format documentation
- `references/prompt.md` — Externalized claude -p prompt

## Output Directory

`/Users/naqi.khan/Documents/Obsidian/LLM History/`

## Hooks

Configured in `~/.claude/settings.json`:
- `Stop` hook — auto-saves on session exit (async)
- `PreCompact` hook — auto-saves when context window triggers compaction (async)
- `SessionEnd` hook — final save on session teardown (sync)

## Distribution

| Surface | Read | Write | Mechanism |
|---------|------|-------|-----------|
| Claude Code CLI | QMD MCP | Auto (hooks) + manual | `~/.claude/skills/llm-history` symlink |
| Claude Desktop | QMD MCP | N/A | QMD indexes Obsidian vault |
| Codex CLI | QMD MCP | Manual only | `~/.agents/skills/llm-history` symlink |
| Codex Desktop | QMD MCP | Manual only | Same as Codex CLI |
