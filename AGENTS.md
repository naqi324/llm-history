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
