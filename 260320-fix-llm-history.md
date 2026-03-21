# llm-history v2 Upgrade — Handoff Document

**Date**: 2026-03-20
**Session**: `1a14df45-c931-4777-b26f-47d5d2d76956` (session_name: `upgrade-llm-history-skill`)
**Project**: `/Users/naqi.khan/git/skills/llm-history`
**Branch**: `main` (all commits pushed to `origin`)
**Status**: In progress — structural improvements shipped, but re-save dedup for resumed sessions is still broken

---

## 1. What This Skill Does

The llm-history skill auto-saves Claude Code session context as structured markdown to `~/Documents/Obsidian/LLM History/` on session exit. It has two components:

- **Dispatcher** (`scripts/llm-history-save.sh`): Called by Stop/PreCompact/SessionEnd hooks. Runs guards, generates filename, forks detached worker.
- **Worker** (`scripts/llm-history-worker.sh`): Calls `claude -p --model sonnet` to summarize the transcript, parses structured metadata (TITLE/TAGS/STATUS), writes frontmatter + body to vault.

Hooks are configured in `~/.claude/settings.json` (Stop async, PreCompact async, SessionEnd sync).

---

## 2. What Was Accomplished (10 commits)

### Commit History (chronological)

| SHA | Description | Status |
|-----|-------------|--------|
| `c7554ac` | Replace JSONL slug extraction with CWD-based project slug | Working |
| `b7e6b8a` | Worker: assistant-only extraction, externalized prompt, YAML-safe output | Working |
| `3c5f9de` | Update template docs with new fields | Working |
| `30248d4` | Update SKILL.md for v2 naming + frontmatter | Working |
| `c50fa99` | CLAUDE.md + AGENTS.md for distribution | Working |
| `766d481` | Fix BSD sed crash on macOS, add session_name capture | Working |
| `92d4b45` | Rewrite prompt for resumption-grade content quality | Working (untested — never triggered) |
| `0ba2de9` | Allow re-save when resumed sessions accumulate new work | Broken (see section 4) |
| `d1237db` | Merge Guards 5+6 into unified dedup that supports resumed sessions | Broken (see section 4) |
| `ac7377c` | Auto-commit on session exit | N/A |

### What Works

1. **First-save path**: New sessions that have never been saved produce output correctly. Verified: `260320-llm-history.md`, `260320-emails.md`, `260320-slack-mcp.md` all created successfully.
2. **Project-based slugs**: Filenames are now `260320-llm-history.md` instead of `260320-you-provide-structured-objective.md`.
3. **Assistant-only extraction**: Worker extracts only `type: "assistant"` messages, eliminating skill injection text pollution.
4. **Session name capture**: `session_name` frontmatter field populated from JSONL `customTitle` entries.
5. **YAML-safe output**: Single-quoted title with `''` escaping. Body written via `printf` to prevent shell expansion.
6. **New frontmatter fields**: `saved_at`, `title`, `session_name`, `status`, content-derived `tags`.
7. **Externalized prompt**: `references/prompt.md` with inline fallback in worker.
8. **Distribution**: Claude Code (hooks + skill), Claude Desktop (QMD read), Codex (AGENTS.md + symlink).

### What Does NOT Work

**Re-save for resumed sessions** — the entire reason the user can't see a `-2` file.

---

## 3. The Original Problems (Pre-Upgrade)

1. **Broken filenames** (~40%): JSONL user messages only contain skill injection text (`"You provide structured, objective critique..."`), not actual user prompts. Slugs captured this garbage. **Fixed by `c7554ac`** — uses CWD basename instead.

2. **Weak content**: Worker extracted both user + assistant messages, polluting claude -p input with skill text. **Fixed by `b7e6b8a`** — assistant-only extraction.

3. **Missing metadata**: No timestamps, status, session name, content-derived tags. **Fixed by `b7e6b8a` + `766d481`**.

4. **Generic prompt**: The claude -p prompt only had section headings, not quality guidance. **Fixed by `92d4b45`** — rewritten with bad/good examples, decision rationale requirements, concrete next steps.

5. **BSD sed crash**: `sed '1,5{/^TITLE:/d; /^TAGS:/d; /^STATUS:/d}'` uses GNU grouping syntax that macOS BSD sed rejects. **Fixed by `766d481`** — portable `sed '/^TITLE:/d; /^TAGS:/d; /^STATUS:/d'`.

---

## 4. The Current Blocker: Re-Save Dedup for Resumed Sessions

### Problem Statement

When a user does `/exit` then `claude --resume`, the session ID stays the same. The lock file from the first save blocks all subsequent saves. This means ANY work done after resuming a session is never captured.

### What Was Tried and Why It Failed

#### Attempt 1: Line-count-aware lock file (`0ba2de9`)

**Idea**: Store transcript line count in the lock file. If the transcript grew by 50+ JSONL lines since the last save, allow a re-save.

**Why it failed**: Guard 6 (vault grep) ran AFTER Guard 5 (line-count check) and unconditionally blocked any session that had a file in the vault. Even when Guard 5 passed, Guard 6 killed it. Guard 6 also corrupted Guard 5's baseline by updating the lock file while blocking.

**Evidence from hook log**:
```
17:01:52 — Guard 5 passes, but Guard 6 finds vault file → BLOCKS, writes line count to lock
17:02:12 — Guard 5 sees prev=1135 now=1142 (7 lines growth from corrupted baseline) → BLOCKS
```

#### Attempt 2: Unified Guard 5+6 (`d1237db`)

**Idea**: Merge the two guards into one. When a lock file exists, only the growth threshold matters (no vault scan). The vault grep only runs when there's no lock file (bootstrap after reboot/clear).

**Why it partially failed**: The unified guard logic IS correct — it properly bootstraps and tracks line counts. But the **50-line growth threshold is wrong**.

**Evidence**: On the first exit after clearing the lock, the guard bootstraps:
```
19:11:40 — SKIP: vault has existing file (no lock), setting lock session=1a14df45
           Lock set to 1435 lines
```

On the next exit (after resume + more work):
```
19:11:59 — SKIP: no significant growth (prev=1435 now=1442) session=1a14df45
           Growth = 7 lines (< 50 threshold)
```

**Current state**: Transcript is at 1463 lines. Lock baseline is 1435. Growth = 28 lines. Still < 50.

### Root Cause Analysis

The 50-line JSONL threshold does not correlate with meaningful work:
- A long conversation with multiple tool calls might add only 10-20 JSONL lines
- The Stop and SessionEnd hooks fire within seconds of each other, each adding a few lines
- Between exit and resume, the transcript grows by metadata/hook entries, not user work
- The actual work done in the session IS substantial, but JSONL line count doesn't reflect it

### Possible Fixes (Not Yet Implemented)

1. **Lower the threshold** (e.g., 10 lines instead of 50). Risk: Stop + SessionEnd race creates false re-saves.
2. **Use file modification time** instead of line count. If the lock file is older than N minutes, allow re-save.
3. **Use transcript byte size** instead of line count. Byte growth correlates better with actual content.
4. **Skip dedup entirely for resumed sessions**. Detect `--resume` via some signal in the hook input or transcript.
5. **Compare actual content hash** of the last 100 assistant messages vs. what was saved.
6. **Remove the lock-based dedup entirely**. Rely only on vault grep + filename dedup counter. Accept occasional duplicate saves as harmless.

---

## 5. File-by-File Current State

### `scripts/llm-history-save.sh` (dispatcher, 161 lines)
- **Guards 1-4**: Working correctly (infinite loop prevention, PreCompact filter, transcript existence, trivial session filter)
- **Guard 5 (unified dedup, lines 65-94)**: Logic is correct but threshold is wrong. The vault grep fallback (no lock file) works. The line-count growth check works. The 50-line threshold is too high for real-world resumed sessions.
- **Filename generation (lines 96-121)**: Working — CWD basename slug, `-2`/`-3` dedup counter.
- **Work file JSON (lines 135-150)**: Clean — removed dead `first_prompt`/`slug` fields.

### `scripts/llm-history-worker.sh` (worker, 196 lines)
- **Transcript extraction (lines 55-60)**: Working — assistant-only, `tail -3000`.
- **Prompt loading (lines 67-83)**: Working — reads `references/prompt.md` with inline fallback.
- **claude -p call (lines 97-101)**: Working — `--model sonnet`, 90s timeout via `run_with_timeout`.
- **Metadata parsing (lines 109-116)**: Working — extracts TITLE/TAGS/STATUS, strips from body.
- **Fallback (lines 120-152)**: Working — extracts recent assistant context on claude -p failure.
- **Frontmatter output (lines 173-191)**: Working — YAML-safe title, printf body, session_name.

### `references/prompt.md` (claude -p prompt, 84 lines)
- Rewritten with resumption-grade quality guidance, bad/good examples, decision rationale format.
- **Untested** — the prompt has never actually been used for a successful save because the re-save dedup blocks it.

### `SKILL.md` (manual invocation, 131 lines)
- Updated for v2: project-based naming, new frontmatter fields, content quality standards.
- Working for manual invocation (unaffected by hook dedup issues).

### `AGENTS.md`, `CLAUDE.md`, `references/template.md`
- Documentation files. All up to date.

---

## 6. Hook Configuration

In `~/.claude/settings.json`:

```json
"Stop": [{ "command": ".../llm-history-save.sh", "timeout": 120, "async": true }],
"PreCompact": [{ "command": ".../llm-history-save.sh", "timeout": 120, "async": true }],
"SessionEnd": [{ "command": ".../llm-history-save.sh", "timeout": 120 }]
```

Stop is async (doesn't block exit). SessionEnd is sync (blocks teardown, up to 120s).

---

## 7. Distribution Status

| Surface | Read | Write | Status |
|---------|------|-------|--------|
| Claude Code CLI | QMD MCP | Hooks + manual `/llm-history` | Working |
| Claude Desktop | QMD MCP | N/A | Working (read-only) |
| Codex CLI | QMD MCP | Manual only | Configured (AGENTS.md + symlink at `~/.agents/skills/llm-history`) |
| Codex Desktop | QMD MCP | Manual only | Same as Codex CLI |

---

## 8. Key Logs and State

### Hook log (`/tmp/llm-history-hook.log`)
Shows every hook invocation with guard outcomes. Key entries for session `1a14df45`:
- `16:43:03` — First successful DISPATCH (created `260320-llm-history.md`)
- `17:01:52` — Guard 6 blocked (before unified guard fix)
- `19:11:40` — Unified guard bootstrapped lock (set baseline to 1435)
- `19:11:59` — SKIP: no significant growth (prev=1435 now=1442)

### Worker log (`/tmp/llm-history-worker.log`)
Shows worker execution. Last successful entry for this session:
- `16:43:33` — DONE session=1a14df45 → 260320-llm-history.md

### Lock file (`/tmp/llm-history-locks/1a14df45-...-save.saved`)
Contains: `1435` (transcript line count at bootstrap time)

### Transcript
- Path: `~/.claude/projects/-Users-naqi-khan-git-skills-llm-history/1a14df45-c931-4777-b26f-47d5d2d76956.jsonl`
- Current size: ~1463 lines, 3.4 MB
- Growth since lock: 28 lines (below 50-line threshold)

---

## 9. Concrete Next Steps

1. **Fix the re-save dedup threshold** in `scripts/llm-history-save.sh:78`. The 50-line JSONL threshold does not correlate with meaningful work. Options:
   - Lower to 10-15 lines (simplest, may cause Stop/SessionEnd race duplicates)
   - Switch to time-based: allow re-save if lock file is older than 5 minutes (`find "$LOCK_FILE" -mmin +5`)
   - Switch to byte-based: compare `wc -c` instead of `wc -l`
   - Remove dedup for the growth path entirely: if lock file exists, always re-save (rely on filename `-2`/`-3` counter to handle duplicates)

2. **Test the prompt quality** by clearing the lock and forcing a save:
   ```bash
   rm -f /tmp/llm-history-locks/1a14df45-*
   rm -f "/Users/naqi.khan/Documents/Obsidian/LLM History/260320-llm-history.md"
   # Then exit a session — should create fresh 260320-llm-history.md with new prompt
   ```

3. **Validate content quality**: Open the newly created file and check:
   - Does it have "Working State", "Failed Approaches", "Concrete Next Steps" sections?
   - Are decisions described with chosen + rejected + why?
   - Are next steps exact commands, not vague suggestions?

4. **Consider removing the lock file mechanism entirely** and using only the vault grep + filename counter. The lock files are in `/tmp` (cleared on reboot), mix old `touch`-style (0 bytes) and new line-count-style formats, and add complexity that has produced three separate bugs.

---

## 10. JSONL Transcript Format (Critical Knowledge)

The Claude Code JSONL transcript has these entry types:

| type | Contains | Useful for slug? |
|------|----------|-----------------|
| `user` | `tool_result` content (95%), skill injection `text` (5%) | NO — text blocks are skill injections only |
| `assistant` | `text` describing actual work done | YES — clean content for summarization |
| `progress` | Hook progress, agent progress (has `prompt` field for subagents) | NO |
| `system` | Local commands, conversation labels | NO |
| `custom-title` | `customTitle` field with Claude Code's auto-assigned session name | YES — extract for `session_name` frontmatter |
| `file-history-snapshot` | File state snapshots | NO |

**The actual user-typed prompt is NOT extractable as a text block.** It's stored as `tool_result` content in user messages. This is why all v1 slugs were garbage — they extracted skill injection text.

---

## 11. Plans That Led Here

### Plan 1: v2 Upgrade (Commits c7554ac through c50fa99)
- Fixed slug generation (CWD basename)
- Upgraded worker (assistant-only extraction, enhanced prompt, YAML-safe output)
- Added new frontmatter fields (saved_at, title, status, session_name)
- Updated docs and distribution

### Plan 2: BSD sed Fix + Session Name (Commit 766d481)
- Fixed `sed '1,5{...}'` crash on macOS (BSD sed doesn't support semicolons in `{}`)
- Added `session_name` extraction from JSONL `customTitle`

### Plan 3: Content Quality Rewrite (Commit 92d4b45)
- Rewrote `references/prompt.md` with resumption-grade quality guidance
- Bad/good examples for every section
- Decision rationale format (chosen + rejected + why + failure mode)
- "Working State" replaces generic "In-Progress Work"
- 300-line limit (up from 200)

### Plan 4: Resumed Session Re-Save (Commits 0ba2de9, d1237db)
- Made Guard 5 line-count-aware (store count in lock, compare on re-entry)
- Merged Guards 5+6 to eliminate unconditional vault grep block
- **Still broken**: 50-line threshold too high for real-world resumed sessions

All plan files were in `/Users/naqi.khan/.claude/plans/nifty-brewing-reef.md` (overwritten each iteration).

---

## 12. Git Remote

```
origin  https://github.com/naqi324/llm-history.git
```

All 10 commits are pushed to `main`.
