#!/usr/bin/env python3

import json
import re
import sys
from pathlib import Path


GENERIC_TAGS = {
    "auto-save",
    "llm-history",
    "session",
    "session-context",
    "session-preservation",
    "workflow",
}

FORBIDDEN_PATTERNS = (
    "could you clarify",
    "what would you like to work on",
    "what would you like me to do",
    "tell me what you want to work on",
    "please let me know what you'd like",
)

# Historical bad-pattern from v1 that our new extractor must never emit.
FORBIDDEN_FILES_CHANGED_STRING = "No concrete file paths were recorded"

# Phrases we refuse to accept as step 1. Matches _GENERIC_NEXT_STEP_DENY
# in scripts/llm-history-context.py.
DENIED_STEP_ONE_PATTERNS = (
    re.compile(r"^run `git status\b[^`]*`\.?\s*$", re.IGNORECASE),
    re.compile(r"^review the code\.?\s*$", re.IGNORECASE),
    re.compile(r"^continue the work\.?\s*$", re.IGNORECASE),
    re.compile(r"^open the file\.?\s*$", re.IGNORECASE),
    re.compile(r"^continue\.?\s*$", re.IGNORECASE),
)

# Minimum expected-concreteness for step 1: must contain a file path
# (contains a '/' or a dotted file extension) OR a backticked command.
STEP_ONE_HAS_PATH = re.compile(r"[/\\]|`[^`]*`")

# Instruction-dump signal at the body level. Long legitimate handoffs can have
# many bullets, so only flag long instruction-shaped runs when skill/prompt
# markers are also present.
INSTRUCTION_LINE = re.compile(r"^\s*(#{1,6}\s|[-*]\s|\d+\.\s|\*\*[^*]+\*\*:)")
INSTRUCTION_MARKERS = (
    "Base directory for this skill:",
    "YAML frontmatter",
    "Supported Flags",
    "Skill Contract",
    "Critical Rules",
    ".claude/skills",
    "SKILL.md",
)


def extract_frontmatter(text: str) -> dict[str, object]:
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return {}
    end = None
    for index in range(1, len(lines)):
        if lines[index].strip() == "---":
            end = index
            break
    if end is None:
        return {}

    data: dict[str, object] = {}
    current_list_key = None
    for line in lines[1:end]:
        if re.match(r"^[A-Za-z0-9_]+:\s*$", line):
            key = line.split(":", 1)[0].strip()
            data[key] = []
            current_list_key = key
            continue
        if line.startswith("  - ") and current_list_key:
            assert isinstance(data[current_list_key], list)
            data[current_list_key].append(line[4:].strip())
            continue
        current_list_key = None
        if ":" in line:
            key, value = line.split(":", 1)
            data[key.strip()] = value.strip().strip("'")
    return data


def section_present(text: str, heading: str) -> bool:
    return f"## {heading}" in text


def section_body(text: str, heading: str) -> str:
    pattern = rf"^## {re.escape(heading)}\n(?P<body>.*?)(?=^## |\Z)"
    match = re.search(pattern, text, flags=re.M | re.S)
    return match.group("body").strip() if match else ""


def is_generic_title(title: str) -> bool:
    lowered = title.lower().strip()
    return (
        not lowered
        or lowered.endswith(" session")
        or lowered.startswith("~/")
        or lowered.startswith("/")
        or lowered in {"auto-save", "auto-save summary", "session summary"}
        or "progress on session work" in lowered
    )


def is_malformed_title(title: str) -> bool:
    """Phase 1.2 rules: reject titles that escaped sanitize_title_text."""
    if not title:
        return True
    if "\n" in title:
        return True
    if title.startswith("#"):
        return True
    if len(title) > 80:
        return True
    if title.startswith("/") or title.startswith("~/"):
        return True
    return False


def has_instruction_dump_section(text: str) -> bool:
    """Return True when a body span still looks like a pasted skill/instruction block."""
    if "Base directory for this skill:" in text:
        return True
    marker_count = sum(1 for marker in INSTRUCTION_MARKERS if marker in text)
    if marker_count < 2:
        return False

    run = 0
    for line in text.splitlines():
        if INSTRUCTION_LINE.match(line):
            run += 1
            if run >= 20:
                return True
        elif line.strip():
            run = 0
    return False


def step_one_is_denied(step_text: str) -> bool:
    cleaned = step_text.strip("- ").strip()
    return any(pattern.match(cleaned) for pattern in DENIED_STEP_ONE_PATTERNS)


def resume_next_action(text: str) -> str:
    section = section_body(text, "Resume Snapshot")
    for line in section.splitlines():
        match = re.match(r"^\s*-\s+Next action:\s+(.+)$", line)
        if match:
            return match.group(1).strip()
    return ""


def main() -> int:
    if len(sys.argv) != 4:
        print("Usage: check_resume_readiness.py <markdown> <bundle-json> <scenario>", file=sys.stderr)
        return 1

    markdown_path = Path(sys.argv[1])
    bundle_path = Path(sys.argv[2])
    scenario = sys.argv[3]

    text = markdown_path.read_text(encoding="utf-8")
    bundle = json.loads(bundle_path.read_text(encoding="utf-8"))
    frontmatter = extract_frontmatter(text)
    failures: list[str] = []

    title = str(frontmatter.get("title", ""))
    tags = [str(tag) for tag in frontmatter.get("tags", [])] if isinstance(frontmatter.get("tags"), list) else []
    lowered_text = text.lower()

    if is_generic_title(title):
      failures.append("generic_title")

    if is_malformed_title(title):
        failures.append("malformed_title")

    meaningful = [tag for tag in tags if tag not in GENERIC_TAGS]
    if not meaningful:
        failures.append("generic_tags")

    for heading in (
        "Resume Snapshot",
        "Task Ledger",
        "Workspace Truth",
        "Decisions And Rationale",
        "Validation Evidence",
        "Risks, Blockers, And Unknowns",
        "Do Not Redo",
    ):
        if not section_present(text, heading):
            failures.append(f"missing_section:{heading}")

    task_ledger = section_body(text, "Task Ledger")
    for subheading in ("DONE", "PARTIALLY DONE", "NOT DONE"):
        if f"### {subheading}" not in task_ledger:
            failures.append(f"missing_task_ledger:{subheading}")

    if any(pattern in lowered_text for pattern in FORBIDDEN_PATTERNS):
        failures.append("forbidden_clarifying_language")

    if FORBIDDEN_FILES_CHANGED_STRING in text:
        failures.append("forbidden_files_changed_string")

    next_action = resume_next_action(text)
    if not next_action:
        failures.append("missing_next_action")
    elif step_one_is_denied(next_action):
        failures.append("denied_next_action")
    elif not STEP_ONE_HAS_PATH.search(next_action):
        failures.append("next_action_not_concrete")

    if has_instruction_dump_section(text):
        failures.append("instruction_dump_in_body")

    required_files = bundle.get("derived", {}).get("required_file_mentions", [])
    if required_files:
        if not any(path in text for path in required_files):
            failures.append("missing_grounded_file_mentions")

    required_checks = bundle.get("derived", {}).get("required_check_mentions", [])
    if required_checks:
        if not any(command in text for command in required_checks):
            failures.append("missing_grounded_check_mentions")

    branch = bundle.get("repo", {}).get("branch", "")
    if bundle.get("repo", {}).get("is_git") and branch:
        workspace_truth = section_body(text, "Workspace Truth")
        if branch not in workspace_truth:
            failures.append("missing_branch_in_workspace_truth")

    if bundle.get("resume_packet", {}).get("validation_events"):
        validation = section_body(text, "Validation Evidence")
        if "->" not in validation:
            failures.append("missing_validation_outcome")

    score = max(0, 100 - (len(failures) * 15))
    report = {
        "scenario": scenario,
        "markdown": str(markdown_path),
        "bundle": str(bundle_path),
        "score": score,
        "passed": not failures,
        "failures": failures,
        "title": title,
        "tags": tags,
    }
    print(json.dumps(report, indent=2))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
