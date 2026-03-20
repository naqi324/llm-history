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
4. Keep the file under 500 lines. Prioritize actionable context over exhaustive logs.
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

Analyze the full conversation to extract:

- **Executive summary**: What was accomplished in 2-4 sentences.
- **Key decisions**: Each decision with its rationale (why, not just what).
- **In-progress work**: Current state of anything incomplete, with enough detail to resume without re-reading code.
- **Relevant files**: File paths that were created, modified, or are central to the work. Include brief descriptions of what was done to each.
- **Key code context**: Only include code snippets that are essential for resumption — new functions, tricky logic, API contracts. Keep these minimal.
- **Next steps**: Specific, actionable items numbered in priority order.
- **Warnings and blockers**: Anything the next session must know — failed approaches, known bugs, environment requirements, pending PRs.

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

<2-4 sentences summarizing what was accomplished and the overall outcome>

## Key Decisions

- **<Decision 1>**: <Rationale — why this approach was chosen>
- **<Decision 2>**: <Rationale>

## In-Progress Work

<Current state of any incomplete work. Include branch names, partially implemented features, or pending changes. Provide enough detail that a fresh session can resume without re-reading all the code.>

## Relevant Files

- `path/to/file1.ext` — <what was done or why it matters>
- `path/to/file2.ext` — <what was done or why it matters>

### Key Code Context

<Only include code snippets that are genuinely essential for resumption. Use fenced code blocks with language identifiers. Omit this subsection entirely if no snippets are needed.>

## Next Steps

1. <Specific actionable item with enough context to execute>
2. <Next item>
3. <Next item>

## Warnings and Blockers

- <Any important caveats, failed approaches, environment issues, or blockers>
- <Omit this section entirely if there are none>
```

Key guidance:
- The H1 title should be a descriptive 5-10 word phrase about what was accomplished, NOT the filename.
- Derive 3-5 tags from session content — never use generic "llm-history" or "auto-save" for manual saves.
- The `status` field should reflect whether the work is completed, in-progress, or blocked.
- Use single quotes around the `title` value in YAML frontmatter to handle special characters.

### Step 6: Confirm

After writing the file, report to the user:
- The full file path
- A one-line summary of what was saved
- The file size (approximate line count)
