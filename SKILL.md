---
name: llm-history
description: Saves session context to Obsidian vault for seamless resumption. Use when users say save session, save context, llm history, save progress, snapshot session, preserve context, checkpoint work, or before exiting. Also use proactively when a session involves significant work that would be costly to reconstruct.
metadata:
  author: naqi-khan
  version: "2.0.0"
  category: workflow-automation
  tags: session-management, obsidian, context-preservation
---

# LLM History

Save the current Claude Code session's context to the Obsidian vault as a structured markdown file, enabling seamless resumption in a new session.

## Critical Rules

1. ALWAYS write the output file to `/Users/naqi.khan/Documents/Obsidian/LLM History/`.
2. NEVER skip the YAML frontmatter block.
3. ALWAYS check for existing files with the same date-project prefix before writing, to handle deduplication.
4. Keep the file under 300 lines. Prioritize actionable specifics over narrative.
5. File names MUST use the format `YYMMDD-<project>.md` where `<project>` is the CWD basename in kebab-case.
6. For multiple saves on the same date/project, append a numeric suffix: `-2`, `-3`, etc.
7. NEVER include full tool outputs, raw API responses, or verbose logs — summarize them.
8. Include enough context that a fresh Claude Code session can resume with zero re-reading of source files.
9. For writing/editing tasks, include the final deliverable text or a substantial excerpt.

## Workflow

### Step 1: Determine File Name

1. Get the project slug from the CWD basename: lowercase, kebab-case, max 25 chars.
2. Format the date as YYMMDD using today's date.
3. Check for existing files with the same date-project prefix to handle deduplication:
   - Use the Glob tool to check `/Users/naqi.khan/Documents/Obsidian/LLM History/` matching `YYMMDD-<project>*.md`.
4. If no match exists, use `YYMMDD-<project>.md`.
5. If matches exist, find the highest numeric suffix and increment it.

### Step 2: Gather Context

Analyze the full conversation to extract a compact resume packet. Write for a Claude Code session that has NEVER seen this codebase and needs to continue without repeating completed work.

- **Resume Snapshot**: goal, current state, exact stopping point, and next concrete action.
- **Task Ledger**: classify work as DONE, PARTIALLY DONE, and NOT DONE. Use explicit todo/checklist state first; otherwise infer carefully from grounded edits, commands, and assistant milestones.
- **Workspace Truth**: repo path, branch, dirty files, changed files, commands with outcomes, and runtime/service state if relevant.
- **Decisions And Rationale**: only decisions that change future work. Include what was chosen and why; omit generic commentary.
- **Validation Evidence**: commands run, pass/fail/unknown outcome, and the important output summary.
- **Risks, Blockers, And Unknowns**: concrete uncertainties or blockers the next agent can act on.
- **Do Not Redo**: completed work and failed approaches the next agent should avoid repeating.

Ground the note in concrete facts whenever possible:
- repo state (`git status --short`, branch, recent commits)
- exact files touched
- exact commands/checks that were run
- explicit unknowns instead of guesses

### Step 3: Retrieve Session ID

Run the following Bash command to get the current session ID:

```bash
ls -t ~/.claude/projects/*/*.jsonl 2>/dev/null | head -1 | xargs basename -s .jsonl
```

This returns the UUID of the most recently active transcript, which is the current session. Always include this in the `session_id` frontmatter field.

### Step 4: Determine Context Usage

Check the current context window usage. If you can determine the approximate percentage (from the status line or your own awareness), include it. Otherwise, write "unknown".

### Step 5: Write the File

Write the file using the Write tool to `/Users/naqi.khan/Documents/Obsidian/LLM History/<filename>.md` with this structure:

```
---
date: YYYY-MM-DD
saved_at: <current ISO 8601 timestamp with timezone>
title: '<descriptive 5-10 word session title>'
model: <model name, e.g., Claude Opus 4.6>
project: <project directory path, use ~ for home>
session_id: <session UUID from Step 3>
context_usage: <approximate percentage, e.g., ~75%>
status: <completed | in-progress | blocked>
trigger: manual
tags:
  - <derived-tag-1>
  - <derived-tag-2>
  - <up to 5 tags derived from session content>
---

# <Descriptive 5-10 Word Session Title>

## Resume Snapshot

- Goal: <what the user was trying to accomplish>
- Current state: <what is true now>
- Exact stopping point: <the last meaningful action, failure, or pause>
- Next action: <one concrete command, file, or action>

## Task Ledger

### DONE

- <completed work>

### PARTIALLY DONE

- <partial work plus what remains>

### NOT DONE

- <remaining work>

## Workspace Truth

- Repo: `<path>` on branch `<branch>`; working tree is <clean|dirty>.
- Dirty files: `<git status --short summary>` or none.
- `<command>` -> <pass|fail|unknown>; <important output if needed>

## Decisions And Rationale

- <decision that affects future work, or "None captured in structured transcript facts.">

## Validation Evidence

- `<command>` -> <pass|fail|unknown>; <important output summary>

## Risks, Blockers, And Unknowns

- <actionable uncertainty, blocker, or none captured>

## Do Not Redo

- <completed work or failed approach to avoid repeating>
```

Key guidance:
- The H1 title should be a descriptive 5-10 word phrase about what was accomplished, NOT the filename.
- Derive 3-5 tags from session content — never use generic "llm-history" or "auto-save" for manual saves.
- The `status` field should reflect whether the work is completed, in-progress, or blocked.
- Always include the seven resume-packet sections shown above for any nontrivial save.
- Never ask clarifying questions or write conversational filler in the saved handoff.
- Use single quotes around the `title` value in YAML frontmatter to handle special characters.

## Gotchas

- **Session ID may be wrong with multiple Claude instances**: The `ls -t ~/.claude/projects/*/*.jsonl | head -1` command returns the most recently modified transcript. If another Claude Code instance is running, this may not be the current session. Cross-check with the CWD project path.
- **Saving near compaction risks incomplete context**: The note reflects what Claude currently remembers, not the full conversation. If context has been compacted, explicitly note which parts may be incomplete in Risks, Blockers, And Unknowns.
- **300-line limit triage order**: When the file exceeds 300 lines, cut in this order: Do Not Redo, Decisions And Rationale, then condense Workspace Truth. Never cut Resume Snapshot, Task Ledger, Validation Evidence, or Risks/Blockers.
- **YAML title values with special characters break Obsidian**: Colons, quotes, and hash characters in the `title` frontmatter field break Obsidian's YAML parser. Always wrap the title value in single quotes.

### Step 6: Confirm

After writing the file, report to the user:
- The full file path
- A one-line summary of what was saved
- The file size (approximate line count)
