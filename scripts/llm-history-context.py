#!/usr/bin/env python3

import json
import os
import re
import subprocess
import sys
from collections import OrderedDict
from pathlib import Path
from typing import Any


GENERIC_TAGS = {
    "auto-save",
    "llm-history",
    "session",
    "session-context",
    "session-preservation",
    "workflow",
}

CHECK_PATTERNS = (
    "test",
    "pytest",
    "smoke",
    "bash -n",
    "sh -n",
    "npm test",
    "npm run test",
    "pnpm test",
    "pnpm run test",
    "yarn test",
    "cargo test",
    "go test",
    "gitleaks",
    "vitest",
    "jest",
)

FAILURE_PATTERNS = (
    "blocked",
    "blocker",
    "broken",
    "error",
    "failed",
    "failure",
    "stuck",
    "unable",
    "didn't work",
    "did not work",
    "warn",
)


def load_json(path: str) -> dict[str, Any]:
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def short_home(path: str) -> str:
    if not path:
        return ""
    home = str(Path.home())
    if path == home:
        return "~"
    if path.startswith(home + os.sep):
        return "~" + path[len(home) :]
    return path


def normalize_path_value(path: str) -> str:
    if not path:
        return ""
    if os.path.isabs(path):
        return os.path.realpath(path)
    return os.path.normpath(path)


def display_path(path: str, repo_root: str | None) -> str:
    if not path:
        return ""
    normalized = normalize_path_value(path)
    if repo_root:
        try:
            relative = os.path.relpath(normalized, repo_root)
            if not relative.startswith(".."):
                return relative
        except ValueError:
            pass
    return short_home(normalized)


def slugify(value: str) -> str:
    value = value.lower()
    value = re.sub(r"[^a-z0-9]+", "-", value)
    value = re.sub(r"-{2,}", "-", value).strip("-")
    return value or "session"


def dedupe(values: list[str], limit: int | None = None) -> list[str]:
    seen: OrderedDict[str, None] = OrderedDict()
    for value in values:
        cleaned = normalize_text(value)
        if not cleaned:
            continue
        seen.setdefault(cleaned, None)
    items = list(seen.keys())
    if limit is not None:
        return items[:limit]
    return items


def normalize_text(value: Any) -> str:
    if value is None:
        return ""
    text = str(value)
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    text = re.sub(r"\s+", " ", text).strip()
    return text


def trim_multiline(value: str, max_lines: int = 8, max_chars: int = 320) -> str:
    lines = [normalize_text(line) for line in value.splitlines()]
    lines = [line for line in lines if line]
    joined = "\n".join(lines[:max_lines])
    return joined[:max_chars].strip()


def tool_result_to_text(content: Any) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts: list[str] = []
        for item in content:
            parts.append(tool_result_to_text(item))
        return "\n".join(part for part in parts if part)
    if isinstance(content, dict):
        if "text" in content:
            return str(content["text"])
        if "content" in content:
            return tool_result_to_text(content["content"])
        return json.dumps(content, sort_keys=True)
    return str(content)


def run_cmd(argv: list[str], cwd: str) -> tuple[bool, str, str]:
    try:
        completed = subprocess.run(
            argv,
            cwd=cwd,
            text=True,
            capture_output=True,
            timeout=2,
            check=False,
        )
    except Exception as exc:
        return False, "", str(exc)
    return completed.returncode == 0, completed.stdout.strip(), completed.stderr.strip()


def classify_checks(commands: list[str]) -> list[str]:
    checks = []
    for command in commands:
        lowered = command.lower()
        if any(pattern in lowered for pattern in CHECK_PATTERNS):
            checks.append(command)
    return dedupe(checks, limit=8)


def collect_failures(texts: list[str]) -> list[str]:
    failures = []
    for text in texts:
        lowered = text.lower()
        if any(pattern in lowered for pattern in FAILURE_PATTERNS):
            failures.append(text)
    return dedupe(failures, limit=6)


def iter_message_blocks(obj: dict[str, Any]) -> list[tuple[str, dict[str, Any]]]:
    blocks: list[tuple[str, dict[str, Any]]] = []

    if obj.get("type") in {"assistant", "user"} and isinstance(obj.get("message"), dict):
        blocks.append((obj["type"], obj["message"]))

    if obj.get("type") == "progress":
        nested = obj.get("data", {}).get("message")
        if isinstance(nested, dict) and nested.get("type") in {"assistant", "user"}:
            message = nested.get("message")
            if isinstance(message, dict):
                blocks.append((nested["type"], message))

    return blocks


def probe_repo(cwd: str) -> dict[str, Any]:
    cwd = normalize_path_value(cwd)
    if not cwd or not os.path.isdir(cwd):
        return {
            "is_git": False,
            "repo_root": "",
            "repo_root_display": "",
            "branch": "",
            "status_short": [],
            "status_clean": True,
            "diff_stat": [],
            "staged_diff_stat": [],
            "recent_commits": [],
            "probe_error": "cwd-missing",
        }

    ok, _, _ = run_cmd(["git", "rev-parse", "--is-inside-work-tree"], cwd)
    if not ok:
        return {
            "is_git": False,
            "repo_root": "",
            "repo_root_display": "",
            "branch": "",
            "status_short": [],
            "status_clean": True,
            "diff_stat": [],
            "staged_diff_stat": [],
            "recent_commits": [],
            "probe_error": "",
        }

    _, repo_root, repo_err = run_cmd(["git", "rev-parse", "--show-toplevel"], cwd)
    _, branch, _ = run_cmd(["git", "branch", "--show-current"], cwd)
    _, status_short, _ = run_cmd(["git", "status", "--short"], cwd)
    _, diff_stat, _ = run_cmd(["git", "diff", "--stat", "--compact-summary"], cwd)
    _, staged_diff, _ = run_cmd(["git", "diff", "--cached", "--stat", "--compact-summary"], cwd)
    _, commits_text, _ = run_cmd(
        ["git", "log", "-3", "--pretty=format:%h%x09%s"],
        cwd,
    )

    recent_commits = []
    for line in commits_text.splitlines():
        if "\t" in line:
            sha, message = line.split("\t", 1)
            recent_commits.append({"sha": sha, "message": message})

    status_lines = [line for line in status_short.splitlines() if line.strip()]
    diff_lines = [line for line in diff_stat.splitlines() if line.strip()]
    staged_lines = [line for line in staged_diff.splitlines() if line.strip()]

    return {
        "is_git": True,
        "repo_root": repo_root,
        "repo_root_display": short_home(repo_root),
        "branch": branch,
        "status_short": status_lines,
        "status_clean": not status_lines,
        "diff_stat": diff_lines[:8],
        "staged_diff_stat": staged_lines[:8],
        "recent_commits": recent_commits,
        "probe_error": repo_err,
    }


def derive_tags(project_slug: str, touched_files: list[str], bash_commands: list[str], repo: dict[str, Any]) -> list[str]:
    tags = [project_slug]

    extensions = set()
    for path in touched_files:
        suffix = Path(path).suffix.lower()
        if suffix:
            extensions.add(suffix)
        lowered = path.lower()
        if "hook" in lowered:
            tags.append("hooks")
        if "prompt" in lowered:
            tags.append("prompting")

    if repo.get("is_git"):
        tags.append("git")

    if bash_commands:
        tags.append("shell-scripting")

    check_commands = classify_checks(bash_commands)
    if check_commands:
        tags.append("testing")

    extension_map = {
        ".sh": "shell-scripting",
        ".py": "python",
        ".ts": "typescript",
        ".tsx": "typescript",
        ".js": "javascript",
        ".jsx": "javascript",
        ".md": "documentation",
        ".json": "json",
        ".yaml": "config",
        ".yml": "config",
    }
    for suffix in sorted(extensions):
        tag = extension_map.get(suffix)
        if tag:
            tags.append(tag)

    cleaned = []
    for tag in dedupe(tags):
        normalized = slugify(tag)
        if normalized and normalized not in GENERIC_TAGS:
            cleaned.append(normalized)
    while len(cleaned) < 3:
        for filler in ("session-handoff", "repo-state", "grounded-context"):
            if filler not in cleaned:
                cleaned.append(filler)
            if len(cleaned) >= 3:
                break
    return cleaned[:5]


def derive_status(repo: dict[str, Any], failures: list[str], assistant_texts: list[str]) -> str:
    combined = " ".join(text.lower() for text in assistant_texts[-6:])
    if failures and any(token in combined for token in ("blocked", "stuck", "unable", "can't", "cannot")):
        return "blocked"
    return "in-progress"


def derive_title(project_slug: str, user_asks: list[str], assistant_texts: list[str]) -> str:
    candidates = user_asks[::-1] + assistant_texts[::-1]
    for text in candidates:
        cleaned = normalize_text(text)
        if not cleaned:
            continue
        cleaned = re.sub(r"^(please|can you|could you|help me|i need you to|need to)\s+", "", cleaned, flags=re.I)
        cleaned = cleaned.strip(".!?")
        cleaned = cleaned.replace("`", "")
        if cleaned.lower().endswith(" session"):
            continue
        if cleaned.startswith("~/") or cleaned.startswith("/"):
            continue
        words = cleaned.split()
        if len(words) >= 3:
            titled = cleaned[:100]
            return titled[0].upper() + titled[1:]
    return f"Progress on {project_slug} work"


def summarize_task(last_user_ask: str, project_dir: str, trigger: str) -> str:
    if last_user_ask:
        return f"The session focused on: {last_user_ask.rstrip('.!?')}."
    return f"Auto-save captured work in `{project_dir}` during `{trigger}`."


def summarize_progress(assistant_milestones: list[str], touched_files: list[str], bash_commands: list[str]) -> str:
    if assistant_milestones:
        lead = assistant_milestones[-1]
        return f"Recent progress: {lead}"
    if touched_files:
        return f"Recent progress touched {len(touched_files)} file(s): {', '.join(touched_files[:3])}."
    if bash_commands:
        return f"Recent work ran {len(bash_commands)} command(s), including `{bash_commands[-1]}`."
    return "Recent progress could only be reconstructed from lightweight session facts."


def summarize_remaining(status: str, repo: dict[str, Any], failures: list[str]) -> str:
    if status == "blocked" and failures:
        return f"Current blocker: {failures[0]}"
    if repo.get("is_git") and repo.get("status_short"):
        return f"The repository is still dirty on `{repo.get('branch') or 'detached'}` and needs another pass before wrap-up."
    return "The work appears to be in progress; use the next steps below to resume from the latest grounded state."


def build_next_steps(repo: dict[str, Any], touched_files: list[str], checks: list[str], failures: list[str], project_dir: str) -> list[str]:
    steps: list[str] = []
    working_dir = repo.get("repo_root_display") or project_dir

    if repo.get("is_git"):
        steps.append(f"Run `cd {working_dir} && git status --short` to confirm the current working tree state.")
    if checks:
        steps.append(f"Re-run `cd {working_dir} && {checks[0]}` and confirm it still passes.")
    if touched_files:
        steps.append(f"Open `{touched_files[0]}` and continue from the latest recorded change in this handoff.")
    if failures:
        steps.append(f"Reproduce and resolve the recorded failure: {failures[0]}")
    if not steps:
        steps.append(f"Re-open the project at `{project_dir}` and continue from the latest session notes in this handoff.")
    return dedupe(steps, limit=4)


def build_file_lines(
    repo_root: str,
    read_files: list[str],
    edited_files: list[str],
    snapshot_files: list[str],
) -> list[str]:
    lines = []
    ordered_paths = []
    for path in edited_files + snapshot_files + read_files:
        if path not in ordered_paths:
            ordered_paths.append(path)

    for path in ordered_paths[:6]:
        display = display_path(path, repo_root or None)
        if path in edited_files or path in snapshot_files:
            detail = "edited during the session and captured in the grounded context."
        else:
            detail = "read during the session for context."
        lines.append(f"- `{display}` — {detail}")
    if not lines:
        lines.append("- No concrete file paths were recorded in the session facts.")
    return lines


def build_working_state_lines(repo: dict[str, Any], checks: list[str], touched_files: list[str]) -> list[str]:
    lines = []
    if repo.get("is_git"):
        branch = repo.get("branch") or "detached"
        status = "clean" if repo.get("status_clean") else "dirty"
        lines.append(f"- Repo: `{repo.get('repo_root_display')}` on branch `{branch}`; working tree is {status}.")
        if repo.get("status_short"):
            joined = "; ".join(repo["status_short"][:4])
            lines.append(f"- Git status: `{joined}`")
        if repo.get("recent_commits"):
            commit_line = ", ".join(f"`{item['sha']}` {item['message']}" for item in repo["recent_commits"][:3])
            lines.append(f"- Recent commits: {commit_line}")
    else:
        lines.append("- `cwd` is not inside a git repository; repo state comes from transcript facts only.")

    if touched_files:
        lines.append(f"- Touched files recorded: {len(touched_files)}")
    if checks:
        lines.append(f"- Verification/check commands seen: `{checks[0]}`")
    return lines


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: llm-history-context.py <work-file>", file=sys.stderr)
        return 1

    work = load_json(sys.argv[1])
    transcript_path = work.get("transcript_path", "")
    cwd = normalize_path_value(work.get("cwd", ""))
    hook_input_json = work.get("hook_input_json", "{}")

    hook_input = json.loads(hook_input_json) if hook_input_json else {}

    session_name = ""
    assistant_texts: list[str] = []
    user_texts: list[str] = []
    bash_commands: list[str] = []
    read_files: list[str] = []
    edit_files: list[str] = []
    write_files: list[str] = []
    tool_names: list[str] = []
    error_results: list[str] = []
    snapshot_files: list[str] = []

    with open(transcript_path, "r", encoding="utf-8") as handle:
        for raw_line in handle:
            line = raw_line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue

            if obj.get("type") == "custom-title":
                session_name = normalize_text(obj.get("customTitle"))

            if obj.get("type") == "file-history-snapshot":
                tracked = obj.get("snapshot", {}).get("trackedFileBackups", {})
                if isinstance(tracked, dict):
                    snapshot_files.extend(normalize_path_value(path) for path in tracked.keys())

            for role, message in iter_message_blocks(obj):
                content = message.get("content", [])
                if not isinstance(content, list):
                    continue
                for item in content:
                    if not isinstance(item, dict):
                        continue
                    item_type = item.get("type")
                    if item_type == "text":
                        text = normalize_text(item.get("text"))
                        if role == "assistant":
                            assistant_texts.append(text)
                        else:
                            user_texts.append(text)
                        continue

                    if item_type == "tool_use" and role == "assistant":
                        name = normalize_text(item.get("name"))
                        tool_names.append(name)
                        payload = item.get("input", {})
                        if not isinstance(payload, dict):
                            continue
                        if name == "Bash":
                            bash_commands.append(normalize_text(payload.get("command")))
                        path = normalize_path_value(normalize_text(payload.get("file_path") or payload.get("path")))
                        if name == "Read" and path:
                            read_files.append(path)
                        elif name in {"Edit", "MultiEdit"} and path:
                            edit_files.append(path)
                        elif name == "Write" and path:
                            write_files.append(path)
                        elif path:
                            read_files.append(path)
                        continue

                    if item_type == "tool_result" and role == "user":
                        result_text = trim_multiline(tool_result_to_text(item.get("content")), max_lines=6, max_chars=260)
                        lowered = result_text.lower()
                        if item.get("is_error") or any(token in lowered for token in ("error", "traceback", "failed")):
                            error_results.append(result_text)

    repo = probe_repo(cwd)
    project_dir = short_home(cwd)
    project_slug = slugify(os.path.basename(cwd) or "session")
    assistant_texts = dedupe(assistant_texts)
    user_texts = dedupe(user_texts)
    bash_commands = dedupe(bash_commands, limit=12)
    read_files = dedupe(read_files, limit=12)
    edit_files = dedupe(edit_files, limit=12)
    write_files = dedupe(write_files, limit=12)
    snapshot_files = dedupe(snapshot_files, limit=12)
    touched_files = dedupe(write_files + edit_files + snapshot_files + read_files, limit=12)
    checks = classify_checks(bash_commands)
    failures = dedupe(error_results + collect_failures(assistant_texts), limit=6)
    assistant_milestones = assistant_texts[-8:]
    recent_user_asks = user_texts[-6:]
    last_user_ask = recent_user_asks[-1] if recent_user_asks else normalize_text(hook_input.get("last_assistant_message"))
    fallback_status = derive_status(repo, failures, assistant_texts)
    grounded_tags = derive_tags(project_slug, touched_files, bash_commands, repo)
    fallback_title = derive_title(project_slug, recent_user_asks, assistant_milestones)
    repo_root = repo.get("repo_root") or ""
    display_touched = [display_path(path, repo_root or None) for path in touched_files]

    bundle = {
        "session": {
            "session_id": normalize_text(work.get("session_id")),
            "session_name": session_name,
            "trigger": normalize_text(work.get("hook_event")),
            "cwd": cwd,
            "project_dir": project_dir,
            "project_slug": project_slug,
            "saved_at": normalize_text(work.get("saved_at")),
            "last_user_ask": last_user_ask,
            "recent_user_asks": recent_user_asks,
            "assistant_milestones": assistant_milestones,
            "assistant_narrative": "\n".join(assistant_texts[-20:]),
            "nontrivial": bool(assistant_milestones or touched_files or bash_commands),
        },
        "repo": repo,
        "tools": {
            "tool_names": dedupe(tool_names, limit=12),
            "bash_commands": bash_commands,
            "likely_checks": checks,
            "read_files": [display_path(path, repo_root or None) for path in read_files],
            "edit_files": [display_path(path, repo_root or None) for path in edit_files],
            "write_files": [display_path(path, repo_root or None) for path in write_files],
            "snapshot_files": [display_path(path, repo_root or None) for path in snapshot_files],
            "touched_files": display_touched,
            "error_results": failures,
        },
        "derived": {
            "grounded_tags": grounded_tags,
            "fallback_title": fallback_title,
            "fallback_status": fallback_status,
            "summary_sentences": [
                summarize_task(last_user_ask, project_dir, normalize_text(work.get("hook_event"))),
                summarize_progress(assistant_milestones, display_touched, bash_commands),
                summarize_remaining(fallback_status, repo, failures),
            ],
            "working_state_lines": build_working_state_lines(repo, checks, display_touched),
            "files_changed_lines": build_file_lines(repo_root, read_files, edit_files + write_files, snapshot_files),
            "next_steps": build_next_steps(repo, display_touched, checks, failures, project_dir),
            "failed_lines": [f"- {line}" for line in failures[:4]],
            "warning_lines": (
                [f"- Repo probe warning: {repo['probe_error']}"] if repo.get("probe_error") else []
            )
            + (
                ["- No file-history snapshot was available; file paths come from tool calls only."]
                if not snapshot_files
                else []
            ),
            "required_file_mentions": display_touched[:3],
            "required_check_mentions": checks[:2],
        },
    }

    print(json.dumps(bundle, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
