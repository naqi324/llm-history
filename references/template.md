# LLM History Output Template

Reference documentation for the markdown files produced by the llm-history skill and hooks.

## YAML Frontmatter Fields

| Field          | Type   | Required | Description                                      |
|----------------|--------|----------|--------------------------------------------------|
| date           | date   | yes      | Session date (YYYY-MM-DD)                        |
| model          | string | yes      | Model used (e.g., "Claude Opus 4.6")             |
| project        | string | yes      | Project directory path (~ for home)              |
| session_id     | string | no       | Claude Code session identifier                   |
| context_usage  | string | no       | Approximate context window usage at save time    |
| trigger        | string | yes      | What triggered the save: manual, Stop, PreCompact|
| tags           | list   | yes      | 2-5 tags derived from session content            |

## Body Sections

### 1. Executive Summary
2-4 sentences summarizing what was accomplished and the session's purpose.

### 2. Key Decisions
Bulleted list of significant decisions with rationale. Omit if no meaningful decisions were made.

### 3. In-Progress Work
Current state of incomplete work with enough detail to resume without re-reading source files. Include branch names, partial implementations, or pending changes. Omit if everything was completed.

### 4. Relevant Files
Bulleted list of file paths that were created, modified, or are central to the work. Each with a brief description of what was done.

#### Key Code Context (subsection)
Essential code snippets in fenced blocks. Only include when the snippet is critical for resumption. Omit entirely when not needed.

### 5. Next Steps
Numbered list of specific, actionable items in priority order. Always present.

### 6. Warnings and Blockers
Caveats, failed approaches, environment requirements, or blockers. Omit if none.

## File Naming Convention

- Format: `YYMMDD-<brief-slug>.md`
- Slug: 2-4 words, kebab-case, derived from the primary task
- Deduplication: append `-2`, `-3`, etc. for multiple saves on the same date with the same slug
- Examples:
  - `260222-refactor-auth-flow.md`
  - `260222-refactor-auth-flow-2.md`
  - `260223-fix-payment-webhook.md`

## Target Directory

`/Users/naqi.khan/Documents/Obsidian/LLM History/`
