# llm-history

Session context preservation skill for Claude Code. Saves structured markdown files to the Obsidian vault for seamless session resumption.

## Structure

- `SKILL.md` — Skill definition (manual `/llm-history` invocation)
- `scripts/llm-history-save.sh` — Hook script for automatic Stop/PreCompact saves
- `references/template.md` — Output format documentation

## Output Directory

`/Users/naqi.khan/Documents/Obsidian/LLM History/`

## Hooks

Configured in `~/.claude/settings.json`:
- `Stop` hook — auto-saves on session exit
- `PreCompact` hook — auto-saves when context window triggers compaction
