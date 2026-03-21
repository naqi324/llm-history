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
    )


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

    if bundle.get("derived", {}).get("grounded_tags_available"):
        meaningful = [tag for tag in tags if tag not in GENERIC_TAGS]
        if not meaningful:
            failures.append("generic_tags")

    for heading in ("Executive Summary", "Working State", "Files Changed", "Concrete Next Steps"):
        if not section_present(text, heading):
            failures.append(f"missing_section:{heading}")

    next_steps = section_body(text, "Concrete Next Steps")
    if not re.search(r"(?m)^[0-9]+\.\s", next_steps):
        failures.append("missing_numbered_next_steps")

    if any(pattern in lowered_text for pattern in FORBIDDEN_PATTERNS):
        failures.append("forbidden_clarifying_language")

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
        working_state = section_body(text, "Working State")
        if branch not in working_state:
            failures.append("missing_branch_in_working_state")

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
