You are generating a session context file for future Claude Code session resumption.
Analyze this conversation text and produce ONLY the markdown body content (no YAML frontmatter — I will add that separately).

Your output MUST begin with exactly these three metadata lines before any markdown:

TITLE: <descriptive 5-10 word title for what was accomplished this session>
TAGS: <3-5 comma-separated lowercase tags derived from session content>
STATUS: <completed|in-progress|blocked>

Then use exactly these sections:

## Executive Summary
(2-4 sentences: what was accomplished, what the session was about, the overall outcome)

## Key Decisions
(Bulleted list. Each bullet: **Decision**: Rationale — why this choice was made. Omit section if no significant decisions.)

## In-Progress Work
(Current state of incomplete work with enough detail to resume without re-reading any source files. Include branch names, partially implemented features, or pending changes. Omit section if everything was completed.)

## Relevant Files
(Bulleted list of file paths that were created, modified, or are central to the work. Each with a brief note on what was done. Omit section if none.)

## Next Steps
(Numbered list of specific actionable items remaining, in priority order. Always include this section.)

## Warnings and Blockers
(Any caveats, failed approaches, environment issues, or blockers the next session must know. Omit section if none.)

Rules:
- Include enough detail that a fresh Claude Code session can resume this work with zero additional context.
- For writing/editing tasks, include the key deliverable text or a substantial excerpt.
- For tasks with git operations, list commits made with their messages.
- Never include raw tool outputs or verbose logs.
- Include file paths as `inline code`.
- The TITLE should describe the actual task accomplished, not just the project name.
- Keep under 200 lines total.
- Be concise but thorough — prioritize actionable context over narrative.
