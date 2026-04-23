# LLM History Output Template

Reference documentation for the markdown files produced by the llm-history skill and hooks.

Rendering is fully deterministic: `scripts/llm-history-worker.sh` builds the markdown from the grounded context bundle emitted by `scripts/llm-history-context.py`. No nested `claude -p` call is made.

## YAML Frontmatter Fields

| Field          | Type   | Required | Description                                      |
|----------------|--------|----------|--------------------------------------------------|
| date           | date   | yes      | Session date (YYYY-MM-DD)                        |
| saved_at       | string | yes      | ISO 8601 timestamp with timezone when saved       |
| title          | string | yes      | Descriptive session title derived from grounded facts |
| model          | string | yes      | Renderer label (`auto-saved (grounded deterministic)`) |
| project        | string | yes      | Project directory path (`~` for home)            |
| session_id     | string | no       | Claude Code session identifier                   |
| session_name   | string | no       | Claude Code auto-assigned session name            |
| status         | string | yes      | completed, in-progress, or blocked               |
| trigger        | string | yes      | What triggered the save: manual, Stop, PreCompact, or SessionEnd |
| tags           | list   | yes      | 3-5 tags derived from session content            |

## Body Sections

### 1. Executive Summary
2-4 sentences summarizing what was accomplished and the session's purpose.

### 2. Working State
Exact current state grounded in transcript and repo facts: branch, cleanliness, checks run, what's done, what's partial, and what remains.

### 3. Files Changed
Bulleted list of concrete file paths touched in the session facts. Only files actually edited or written appear; files only read for context are not listed as changed.

### 4. Concrete Next Steps
Numbered list of specific, actionable items with exact commands, file paths, or checks. Always present.

### 5. Failed Approaches
Optional. Included only when the grounded facts show a real failure, blocker, or rejected path.

### 6. Warnings
Optional. Included when the grounded facts record environment warnings, fragile assumptions, or probe errors.

## File Naming Convention

- Format: `YYMMDD-<project>.md`
- Project slug: derived from CWD basename (lowercase, kebab-case, max 25 chars)
- Deduplication: append `-2`, `-3`, etc. for multiple saves on the same date with the same project
- Examples:
  - `260320-llm-history.md`
  - `260319-browser.md`
  - `260320-llm-history-2.md`

## Target Directory

`/Users/naqi.khan/Documents/Obsidian/LLM History/`
