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

Analyze the full conversation to extract the following. Write for a Claude Code session that has NEVER seen this codebase — every section must be self-contained and actionable.

- **Executive summary**: 2-4 sentences stating (1) what the task was, (2) what was accomplished, (3) what remains. Be specific — not "updated config files" but "rewrote auth middleware to use JWT across 3 route handlers."
- **Key decisions**: For each decision, include: what was chosen, what was rejected, why, and what failure mode was avoided. This prevents the next session from re-debating settled questions.
- **Working state**: The exact state of the codebase RIGHT NOW — what is done and verified, what is untested, what is partially done (with the exact interruption point), what hasn't started. Include branch name, uncommitted changes, active config/hooks.
- **Files changed**: Each file path with what specifically was changed (not just "updated") and its current state (working/untested/broken). Include 1-3 code snippets ONLY when they show non-obvious logic. Use `file:line` references.
- **Concrete next steps**: Each step must include the exact command, file path, or specific check. Never write "review the code" — specify WHICH file, WHICH function, WHAT to verify.
- **Failed approaches**: What was tried and didn't work, with the specific error or reason. Prevents retrying dead ends.
- **Warnings**: Environment requirements, known bugs, fragile assumptions, or platform-specific gotchas.

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

## Executive Summary

<2-4 sentences: (1) what the task was, (2) what was accomplished, (3) what remains>

## Key Decisions

- **<What was chosen>** over <what was rejected>: <Why — concrete reason>. <What would go wrong with the rejected approach.>

## Working State

<Exact codebase state: what's done+verified, what's untested, what's partial (with interruption point), what hasn't started. Branch, uncommitted changes, active config/hooks.>

## Files Changed

- `path/to/file1.ext` — <specific change made, current state>
- `path/to/file2.ext` — <specific change made, current state>

<Include 1-3 code snippets only when they show non-obvious logic. Use file:line refs.>

## Concrete Next Steps

1. <Exact command or file path — independently executable, no ambiguity>
2. <Next step with expected output or success criteria>

## Failed Approaches

- <What was tried, the specific error, why it didn't work. Omit section if nothing failed.>

## Warnings

- <Environment requirements, known bugs, fragile assumptions. Omit section if none.>
```

Key guidance:
- The H1 title should be a descriptive 5-10 word phrase about what was accomplished, NOT the filename.
- Derive 3-5 tags from session content — never use generic "llm-history" or "auto-save" for manual saves.
- The `status` field should reflect whether the work is completed, in-progress, or blocked.
- Always include `## Executive Summary`, `## Working State`, `## Files Changed`, and `## Concrete Next Steps` for any nontrivial save.
- Never ask clarifying questions or write conversational filler in the saved handoff.
- Use single quotes around the `title` value in YAML frontmatter to handle special characters.

### Step 6: Confirm

After writing the file, report to the user:
- The full file path
- A one-line summary of what was saved
- The file size (approximate line count)
