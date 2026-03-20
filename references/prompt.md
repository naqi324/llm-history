You are generating a session handoff document. Its sole purpose is enabling a fresh Claude Code session to resume this work with zero re-reading of source files and zero re-debating of settled decisions.

Your output MUST begin with exactly these three metadata lines before any markdown:

TITLE: <descriptive 5-10 word title for what was accomplished>
TAGS: <3-5 comma-separated lowercase tags derived from content>
STATUS: <completed|in-progress|blocked>

Then use these sections:

## Executive Summary
2-4 sentences. State: (1) what the task was, (2) what was accomplished, (3) what remains. Be specific — not "updated config files" but "rewrote auth middleware to use JWT instead of session cookies across 3 route handlers."

## Key Decisions
For each significant decision:
- **What was chosen**: The specific approach taken
- **What was rejected**: The alternative(s) considered
- **Why**: The concrete reason — performance, compatibility, simplicity, etc.
- **Failure mode avoided**: What would go wrong with the rejected approach

This section prevents the next session from re-debating settled questions.
Bad: "Used assistant-only extraction"
Good: "Used assistant-only extraction instead of filtering user messages because user message text blocks in the JSONL only contain skill injection text ('You provide structured, objective critique...'), not actual user prompts. Filtering user messages would still pass through this garbage."

Omit section if no significant decisions.

## Working State
The exact state of the codebase RIGHT NOW:
- What is done and verified working (with how it was verified)
- What is done but untested
- What is partially done (with exact point of interruption)
- What has NOT been started
- Branch name if not main
- Uncommitted changes if any
- Config/environment state (what's configured, what hooks are active, what services are running)

Bad: "All changes committed"
Good: "6 commits on main, all pushed to origin. The dispatcher (save.sh) and worker (worker.sh) are updated. Hook config in ~/.claude/settings.json is unchanged — Stop/PreCompact/SessionEnd all point to save.sh. Lock dir at /tmp/llm-history-locks/ was manually cleared."

Omit section if trivial (e.g., a single quick-answer session).

## Files Changed
For each file created or modified:
- Full path
- What specifically was changed (not just "updated" — the actual change)
- Current state (working? needs testing? has known issue?)

Include 1-3 essential code snippets ONLY when they show non-obvious logic a new session must understand. Use `file:line` references when pointing to specific locations.

Omit section if no files were changed.

## Concrete Next Steps
Numbered list. Each step must be independently actionable — include exact commands, file paths, or specific checks. No ambiguity.

Bad: "Test the output quality"
Good: "1. Exit a Claude Code session and wait 30s
2. Check log: tail -5 /tmp/llm-history-worker.log
3. Expected output: DONE session=<uuid> -> /path/to/file.md
4. Open the .md file and verify: saved_at has timezone, title is descriptive, tags are content-derived"

Always include this section.

## Failed Approaches
What was tried and didn't work, with the specific error or reason it failed. Prevents the next session from retrying dead ends.

Bad: "Tried a different approach first"
Good: "Tried extracting user prompts from JSONL text blocks, but user message text blocks only contain skill injection content ('Base directory for this skill: ...'), not the actual user-typed prompt. The real prompt is stored as tool_result content which is not extractable as plain text."

Omit section if nothing failed.

## Warnings
Environment requirements, known bugs, fragile assumptions, platform-specific gotchas, or things that will break if assumptions change. Omit section if none.

Rules:
- Write for a Claude Code session that has NEVER seen this codebase.
- Every decision must include what was rejected and why.
- Every next step must include the exact command, file path, or specific action.
- Include before/after examples when explaining fixes (what the bug looked like vs. the fix).
- Show what success looks like (expected output, log lines, file state).
- Never say "review the code" — specify WHICH file, WHICH function, WHAT to check.
- For writing/editing tasks, include the key deliverable text or a substantial excerpt.
- For git operations, list commits with their messages and SHAs.
- Keep under 300 lines total. Prioritize actionable specifics over narrative.
