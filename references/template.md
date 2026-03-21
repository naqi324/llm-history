# LLM History Output Template

Reference documentation for the markdown files produced by the llm-history skill and hooks.

## YAML Frontmatter Fields

| Field          | Type   | Required | Description                                      |
|----------------|--------|----------|--------------------------------------------------|
| date           | date   | yes      | Session date (YYYY-MM-DD)                        |
| saved_at       | string | yes      | ISO 8601 timestamp with timezone when saved       |
| title          | string | yes      | Descriptive session title from grounded facts or model output |
| model          | string | yes      | Renderer used for the save (model-backed or deterministic) |
| project        | string | yes      | Project directory path (~ for home)              |
| session_id     | string | no       | Claude Code session identifier                   |
| session_name   | string | no       | Claude Code auto-assigned session name            |
| context_usage  | string | no       | Approximate context window usage (manual only)   |
| status         | string | yes      | completed, in-progress, or blocked               |
| trigger        | string | yes      | What triggered the save: manual, Stop, PreCompact, or SessionEnd |
| tags           | list   | yes      | 3-5 tags derived from session content            |

## Body Sections

### 1. Executive Summary
2-4 sentences summarizing what was accomplished and the session's purpose.

### 2. Key Decisions
Bulleted list of significant decisions with rationale. Omit if no meaningful decisions were made.

### 3. Working State
Exact current state grounded in transcript and repo facts: branch, cleanliness, checks run, what's done, what's partial, and what remains.

### 4. Files Changed
Bulleted list of concrete file paths touched in the session facts, each with what happened and why it matters.

### 5. Concrete Next Steps
Numbered list of specific, actionable items with exact commands, file paths, or checks. Always present.

### 6. Key Decisions / Failed Approaches / Warnings
Optional sections included only when the grounded facts support them.

## Worker Validation and Fallback

- Structured Claude output must begin with `TITLE:`, `TAGS:`, and `STATUS:` on the first three lines.
- Accepted `status` values are `completed`, `in-progress`, or `blocked`.
- Model output is also rejected when it is low-value, including:
  - generic/path-only titles
  - generic-only tags when grounded facts exist
  - missing `Executive Summary`, `Working State`, `Files Changed`, or `Concrete Next Steps`
  - missing numbered next steps
  - clarifying-question style prose
  - omission of grounded file/command facts that the worker marked as required
- `SessionEnd` saves are always rendered deterministically from the grounded context bundle so shutdown never depends on a nested Claude subprocess.
- If the Claude subprocess returns malformed or low-value output in non-exit flows, the worker falls back to a deterministic grounded handoff built from the same context bundle.

## File Naming Convention

- Format: `YYMMDD-<project>.md`
- Project slug: derived from CWD basename (lowercase, kebab-case, max 25 chars)
- Deduplication: append `-2`, `-3`, etc. for multiple saves on the same date with the same project
- Descriptive task naming lives in the H1 heading and `title` frontmatter field
- Examples:
  - `260320-llm-history.md`
  - `260319-browser.md`
  - `260320-llm-history-2.md`

## Target Directory

`/Users/naqi.khan/Documents/Obsidian/LLM History/`
