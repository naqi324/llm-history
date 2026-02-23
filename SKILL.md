---
name: llm-history
description: Saves session context to Obsidian vault for seamless resumption. Use when users say save session, save context, llm history, save progress, snapshot session, preserve context, or before exiting.
metadata:
  author: naqi-khan
  version: "1.0.0"
  category: workflow-automation
  tags: session-management, obsidian, context-preservation
---

# LLM History

Save the current Claude Code session's context to the Obsidian vault as a structured markdown file, enabling seamless resumption in a new session.

## Critical Rules

1. ALWAYS write the output file to `/Users/naqi.khan/Documents/Obsidian/LLM History/`.
2. NEVER skip the YAML frontmatter block.
3. ALWAYS check for existing files with the same date-slug prefix before writing, to handle deduplication.
4. Keep the file under 500 lines. Prioritize actionable context over exhaustive logs.
5. File names MUST use the format `YYMMDD-<brief-slug>.md` (e.g., `260222-refactor-auth-flow.md`).
6. For multiple saves in the same session, append a numeric suffix: `-2`, `-3`, etc.
7. NEVER include full tool outputs, raw API responses, or verbose logs — summarize them.
8. DO include enough context that a fresh Claude Code session can pick up the work with no additional explanation.

## Workflow

### Step 1: Determine File Name

1. Generate a brief slug (2-4 words, kebab-case) that captures the primary task or project of this session.
2. Format the date as YYMMDD using today's date.
3. Check for existing files with the same date-slug prefix to handle deduplication:
   - **If Obsidian is running**: use `obsidian search query="YYMMDD-<slug>" folder="LLM History"` via the obsidian-cli skill.
   - **Fallback**: use the Glob tool to check `/Users/naqi.khan/Documents/Obsidian/LLM History/` matching `YYMMDD-<slug>*.md`.
4. If no match exists, use `YYMMDD-<slug>.md`.
5. If matches exist, find the highest numeric suffix and increment it. For example, if `260222-auth-flow.md` and `260222-auth-flow-2.md` exist, use `260222-auth-flow-3.md`.

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
model: <model name, e.g., Claude Opus 4.6>
project: <project directory path, use ~ for home>
session_id: <session UUID from Step 3>
context_usage: <approximate percentage, e.g., ~75%>
trigger: manual
tags:
  - <derived-tag-1>
  - <derived-tag-2>
  - <up to 5 tags derived from session content>
---

# <Descriptive Session Title>

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

### Step 6: Confirm

After writing the file, report to the user:
- The full file path
- A one-line summary of what was saved
- The file size (approximate line count)

## Proactive Behavior

This skill should also be offered proactively by Claude when:
- The user mentions exiting, quitting, stopping, or ending the session
- The user says they need to take a break or will come back later
- The conversation has been long and productive with significant accumulated context
- Context window pressure appears high (compaction has occurred or is imminent)

When offering proactively, say: "Want me to save session context before we wrap up? (`/llm-history`)"
