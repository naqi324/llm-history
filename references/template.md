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

### 1. Resume Snapshot
Four bullets: goal, current state, exact stopping point, and next concrete action.

### 2. Task Ledger
Three subsections: DONE, PARTIALLY DONE, and NOT DONE. Uses explicit todos/checklists first, then grounded transcript facts.

### 3. Workspace Truth
Repo path, branch, dirty files, changed files, relevant commands with outcomes, and runtime/service state when captured.

### 4. Decisions And Rationale
Only decisions that change future work. If none are captured, the section says so explicitly.

### 5. Validation Evidence
Validation commands with pass, fail, or unknown outcome and a concise output summary when available.

### 6. Risks, Blockers, And Unknowns
Actionable uncertainties, blockers, failed commands, or plan-mode warnings. If none are captured, the section says so explicitly.

### 7. Do Not Redo
Completed work and failed approaches that the next agent should not repeat.

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
