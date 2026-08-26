#!/usr/bin/env python3
"""Aggregate local Codex usage without sending conversation data anywhere."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import defaultdict
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Any


CACHE_VERSION = 8
TOKEN_KEYS = (
    "total_tokens",
    "input_tokens",
    "cached_input_tokens",
    "output_tokens",
    "reasoning_output_tokens",
)
SKILL_PATH_RE = re.compile(r"[\\/]([^\\/\"']+)[\\/]SKILL\.md", re.IGNORECASE)
EXPLICIT_SKILL_RE = re.compile(r"(?<![\w-])\$([A-Za-z0-9_.:-]+)")
SKILL_CATALOG_RE = re.compile(
    r"^-\s+(.+?):\s+.*?\(file:\s*(.+?[\\/]SKILL\.md)\)\s*$",
    re.IGNORECASE | re.MULTILINE,
)
NESTED_TOOL_RE = re.compile(r"tools\.([A-Za-z0-9_]+)\s*\(")
POWERSHELL_SCOPE_PREFIXES = ("env:", "global:", "local:", "private:", "script:")


def parse_timestamp(value: Any) -> datetime | None:
    if not value:
        return None
    try:
        text = str(value)
        if text.endswith("Z"):
            text = text[:-1] + "+00:00"
        parsed = datetime.fromisoformat(text)
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        return parsed.astimezone()
    except (TypeError, ValueError, OverflowError):
        return None


def empty_usage() -> dict[str, int]:
    return {key: 0 for key in TOKEN_KEYS}


def normalize_usage(raw: Any) -> dict[str, int]:
    if not isinstance(raw, dict):
        return empty_usage()
    result = empty_usage()
    for key in TOKEN_KEYS:
        try:
            result[key] = max(0, int(raw.get(key, 0) or 0))
        except (TypeError, ValueError, OverflowError):
            result[key] = 0
    return result


def add_usage(target: dict[str, int], delta: dict[str, int]) -> None:
    for key in TOKEN_KEYS:
        target[key] = int(target.get(key, 0)) + int(delta.get(key, 0))


def usage_delta(current: dict[str, int], previous: dict[str, int]) -> dict[str, int] | None:
    current_total = current["total_tokens"]
    previous_total = previous["total_tokens"]
    if current_total <= 0 or current_total <= previous_total:
        return None
    delta = {key: max(0, current[key] - previous[key]) for key in TOKEN_KEYS}
    if delta["total_tokens"] <= 0:
        return None
    return delta


def normalize_skill_name(value: Any) -> str | None:
    name = str(value or "").strip()
    if (
        not name
        or name.lower().startswith(POWERSHELL_SCOPE_PREFIXES)
        or "<" in name
        or ">" in name
    ):
        return None
    return name


def ordered_unique(values: Any) -> list[str]:
    result: list[str] = []
    seen: set[str] = set()
    for value in values or []:
        name = normalize_skill_name(value)
        if not name:
            continue
        key = name.lower()
        if key not in seen:
            seen.add(key)
            result.append(name)
    return result


def extract_skills_from_tool_input(value: Any) -> list[str]:
    if not isinstance(value, str) or "SKILL.MD" not in value.upper():
        return []
    return ordered_unique(match.group(1) for match in SKILL_PATH_RE.finditer(value))


def extract_explicit_skills(value: Any) -> list[str]:
    if not isinstance(value, str):
        return []
    return ordered_unique(match.group(1) for match in EXPLICIT_SKILL_RE.finditer(value))


def classify_skill_scope(path: str) -> str:
    normalized = path.replace("\\", "/").lower()
    if "/.codex/plugins/" in normalized:
        return "PLUGIN"
    if "/.codex/skills/.system/" in normalized:
        return "SYSTEM"
    if "/.codex/skills/" in normalized:
        return "PERSONAL"
    if "/.agents/skills/" in normalized:
        home_marker = str(Path.home()).replace("\\", "/").lower().rstrip("/") + "/.agents/skills/"
        return "USER" if normalized.startswith(home_marker) else "REPO"
    return "OTHER"


def extract_skill_catalog(value: Any) -> list[dict[str, str]]:
    if not isinstance(value, str) or "<skills_instructions>" not in value:
        return []
    entries: list[dict[str, str]] = []
    seen: set[str] = set()
    for match in SKILL_CATALOG_RE.finditer(value):
        name = normalize_skill_name(match.group(1))
        path = match.group(2).strip()
        if not name or name.lower() in seen:
            continue
        seen.add(name.lower())
        entries.append({"name": name, "path": path, "scope": classify_skill_scope(path)})
    return entries


def extract_tool_names(name: Any, tool_input: Any) -> list[str]:
    """Return the concrete tools behind both direct and unified exec calls."""
    direct = str(name or "").strip()
    nested = NESTED_TOOL_RE.findall(tool_input) if isinstance(tool_input, str) else []
    if nested:
        return ordered_unique(nested)
    return [direct] if direct else []


def classify_tool(tool_name: str) -> str:
    normalized = tool_name.lower()
    if normalized.startswith("mcp__") or normalized.startswith("codex_app") or normalized in {
        "list_mcp_resources",
        "list_mcp_resource_templates",
        "read_mcp_resource",
    }:
        return "connector"
    if normalized in {"wait", "send_message", "spawn_agent"} or any(
        marker in normalized
        for marker in ("spawn_agent", "wait_agent", "send_message", "followup_task", "interrupt_agent", "list_agents", "multi_agent")
    ):
        return "agent"
    if normalized in {"exec_command", "shell_command", "write_stdin", "exec", "shell", "py", "cpython"}:
        return "command"
    if normalized in {"apply_patch"}:
        return "file"
    if "web" in normalized or normalized in {"search", "browser"}:
        return "web"
    if any(marker in normalized for marker in ("image_gen", "imagegen", "view_image", "screenshot", "audio")):
        return "media"
    if any(marker in normalized for marker in ("spreadsheet", "excel", "document", "pdf", "presentation", "slide")):
        return "document"
    if normalized in {"update_plan", "request_user_input", "create_goal", "get_goal", "update_goal"}:
        return "workflow"
    return "other"


def mcp_server_name(tool_name: str) -> str:
    parts = tool_name.split("__")
    if len(parts) >= 3 and parts[1] == "codex_apps":
        suffix = parts[2]
        integration = suffix
        for marker in ("_get_", "_list_", "_create_", "_update_", "_delete_", "_remove_", "_execute_", "_search_"):
            if marker in suffix:
                integration = suffix.split(marker, 1)[0]
                break
        return f"codex_apps/{integration}"
    if len(parts) >= 2:
        return parts[1]
    return "MCP"


def tool_output_failed(payload: dict[str, Any]) -> bool:
    if payload.get("is_error") is True or str(payload.get("status") or "").lower() in {"failed", "error"}:
        return True
    output = payload.get("output")
    if isinstance(output, dict) and output.get("isError") is True:
        return True
    text = json.dumps(output, ensure_ascii=False) if not isinstance(output, str) else output
    lowered = text.lstrip().lower()
    return bool(
        re.search(r'"isError"\s*:\s*true', text, re.IGNORECASE)
        or re.search(r'"exit_code"\s*:\s*[1-9][0-9]*', text, re.IGNORECASE)
        or lowered.startswith(("script failed", "script error", "tool failed"))
    )


def discover_installed_skills(roots: list[Path]) -> list[str]:
    found: dict[str, str] = {}
    for root in roots:
        if not root.exists():
            continue
        try:
            for child in root.iterdir():
                if child.is_dir() and (child / "SKILL.md").is_file():
                    found.setdefault(child.name.lower(), child.name)
        except OSError:
            continue
    return sorted(found.values(), key=str.lower)


def split_toml_section(value: str) -> list[str]:
    return [
        token[1:-1].replace('\\"', '"') if token.startswith('"') else token
        for token in re.findall(r'"(?:[^"\\]|\\.)*"|[^.]+', value)
    ]


def parse_codex_config(path: Path) -> dict[str, Any]:
    result = {"mcpServers": {}, "plugins": {}, "pluginMcpServers": {}}
    if not path.is_file():
        return result
    sections: dict[tuple[str, ...], dict[str, str]] = defaultdict(dict)
    current: tuple[str, ...] = ()
    try:
        for raw_line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            line = raw_line.strip()
            section = re.match(r"^\[([^\]]+)\]", line)
            if section:
                current = tuple(split_toml_section(section.group(1)))
                continue
            assignment = re.match(r"^([A-Za-z0-9_-]+)\s*=\s*(.+?)\s*$", line)
            if current and assignment:
                sections[current][assignment.group(1)] = assignment.group(2).split("#", 1)[0].strip()
    except OSError:
        return result

    for parts, values in sections.items():
        enabled = str(values.get("enabled", "true")).lower() != "false"
        if len(parts) == 2 and parts[0] == "mcp_servers":
            result["mcpServers"][parts[1]] = enabled
        if len(parts) == 2 and parts[0] == "plugins":
            result["plugins"][parts[1]] = enabled
        if len(parts) >= 4 and parts[0] == "plugins" and parts[2] == "mcp_servers":
            key = f"{parts[1]}/{parts[3]}"
            result["pluginMcpServers"][key] = enabled
            result["plugins"].setdefault(parts[1], True)
    return result


def choose_primary_skill(trace: list[str]) -> str | None:
    """Treat the final observed Skill as the primary executor, independent of its name."""
    return trace[-1] if trace else None


def choose_skill_trace(loaded_skills: Any, explicit_skills: Any) -> list[str]:
    """Prefer ordered file-load evidence without discarding genuine long chains."""
    for candidate in (ordered_unique(loaded_skills), ordered_unique(explicit_skills)):
        if candidate:
            return candidate
    return []


def classify_agent(meta: dict[str, Any]) -> str:
    if not meta.get("parent_thread_id"):
        return "ROOT"
    role = str(meta.get("agent_role") or "").strip()
    if role:
        return role
    nickname = str(meta.get("agent_nickname") or "").strip()
    if nickname:
        return nickname
    return "SUBAGENT"


def parse_rollout(path: Path) -> dict[str, Any]:
    meta: dict[str, Any] = {}
    turns: dict[str, dict[str, Any]] = {}
    rate_snapshots: list[dict[str, Any]] = []
    skill_catalogs: list[dict[str, Any]] = []
    tool_calls: list[dict[str, Any]] = []
    pending_tool_calls: defaultdict[str, list[int]] = defaultdict(list)
    last_rate_signature: tuple[Any, ...] | None = None
    current_turn = "unattributed-turn"
    previous_total = empty_usage()

    def get_turn(turn_id: str) -> dict[str, Any]:
        return turns.setdefault(
            turn_id,
            {
                "date": None,
                "usage": empty_usage(),
                "skills": set(),
                "explicitSkills": [],
                "loadedSkills": [],
                "model": None,
                "effort": None,
                "cwd": None,
                "completed": False,
            },
        )

    def add_skill_evidence(turn_id: str, names: list[str], source: str) -> None:
        turn = get_turn(turn_id)
        target = turn["loadedSkills"] if source == "loaded" else turn["explicitSkills"]
        existing = {str(value).lower() for value in target}
        for name in names:
            normalized = normalize_skill_name(name)
            if not normalized:
                continue
            turn["skills"].add(normalized)
            key = normalized.lower()
            if key not in existing:
                existing.add(key)
                target.append(normalized)

    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            try:
                record = json.loads(line)
            except (json.JSONDecodeError, TypeError):
                continue

            top_type = record.get("type")
            payload = record.get("payload")
            if not isinstance(payload, dict):
                payload = {}

            if top_type == "session_meta":
                meta = payload
                continue

            if top_type == "turn_context":
                turn_id = payload.get("turn_id")
                if turn_id:
                    current_turn = str(turn_id)
                    turn = get_turn(current_turn)
                    observed = parse_timestamp(record.get("timestamp"))
                    if observed and not turn["date"]:
                        turn["date"] = observed.date().isoformat()
                    turn["model"] = payload.get("model") or turn["model"]
                    turn["effort"] = payload.get("effort") or turn["effort"]
                    turn["cwd"] = payload.get("cwd") or turn["cwd"]
                continue

            if top_type == "event_msg" and payload.get("type") == "user_message":
                message = payload.get("message")
                if message is None:
                    message = payload.get("text")
                add_skill_evidence(current_turn, extract_explicit_skills(message), "explicit")

            if top_type == "response_item":
                response_type = payload.get("type")
                if (
                    response_type == "message"
                    and payload.get("role") == "assistant"
                    and payload.get("phase") == "final_answer"
                ):
                    turn = get_turn(current_turn)
                    turn["completed"] = True
                    observed = parse_timestamp(record.get("timestamp"))
                    if observed:
                        turn["date"] = observed.date().isoformat()

                if response_type == "message" and payload.get("role") == "developer":
                    for part in payload.get("content") or []:
                        if not isinstance(part, dict):
                            continue
                        entries = extract_skill_catalog(part.get("text"))
                        if entries:
                            skill_catalogs.append(
                                {"timestamp": record.get("timestamp"), "entries": entries}
                            )

                if response_type in {"custom_tool_call", "function_call"}:
                    tool_input = payload.get("input")
                    if tool_input is None:
                        tool_input = payload.get("arguments")
                    add_skill_evidence(current_turn, extract_skills_from_tool_input(tool_input), "loaded")
                    observed = parse_timestamp(record.get("timestamp"))
                    call_key = str(payload.get("call_id") or payload.get("id") or "")
                    for tool_name in extract_tool_names(payload.get("name"), tool_input):
                        category = classify_tool(tool_name)
                        index = len(tool_calls)
                        tool_calls.append(
                            {
                                "timestamp": observed.isoformat() if observed else None,
                                "date": observed.date().isoformat() if observed else None,
                                "turnId": current_turn,
                                "tool": tool_name,
                                "category": category,
                                "server": mcp_server_name(tool_name) if category == "connector" else None,
                                "status": "observed",
                            }
                        )
                        if call_key:
                            pending_tool_calls[call_key].append(index)

                if response_type in {"custom_tool_call_output", "function_call_output"}:
                    call_key = str(payload.get("call_id") or payload.get("id") or "")
                    status = "failed" if tool_output_failed(payload) else "completed"
                    for index in pending_tool_calls.pop(call_key, []):
                        tool_calls[index]["status"] = status

            if top_type != "event_msg" or payload.get("type") != "token_count":
                continue

            observed = parse_timestamp(record.get("timestamp"))
            info = payload.get("info")
            if isinstance(info, dict):
                current_total = normalize_usage(info.get("total_token_usage"))
                delta = usage_delta(current_total, previous_total)
                if current_total["total_tokens"] < previous_total["total_tokens"]:
                    previous_total = current_total
                elif current_total["total_tokens"] >= previous_total["total_tokens"]:
                    previous_total = current_total
                if delta:
                    turn = get_turn(current_turn)
                    add_usage(turn["usage"], delta)
                    if observed:
                        turn["date"] = observed.date().isoformat()

            rate_limits = payload.get("rate_limits")
            if isinstance(rate_limits, dict):
                primary = rate_limits.get("primary")
                if isinstance(primary, dict) and primary.get("used_percent") is not None:
                    try:
                        snapshot = {
                            "timestamp": observed.isoformat() if observed else None,
                            "usedPercent": float(primary.get("used_percent")),
                            "resetEpoch": int(primary.get("resets_at")) if primary.get("resets_at") is not None else None,
                            "windowMinutes": int(primary.get("window_minutes")) if primary.get("window_minutes") is not None else None,
                            "limitId": str(rate_limits.get("limit_id") or "primary"),
                        }
                        signature = (
                            snapshot["usedPercent"],
                            snapshot["resetEpoch"],
                            snapshot["windowMinutes"],
                            snapshot["limitId"],
                        )
                        if snapshot["timestamp"] and signature != last_rate_signature:
                            rate_snapshots.append(snapshot)
                            last_rate_signature = signature
                    except (TypeError, ValueError, OverflowError):
                        pass

    agent = classify_agent(meta)
    serialized_turns = []
    for turn_id, value in turns.items():
        if value["usage"]["total_tokens"] <= 0:
            continue
        loaded_skills = ordered_unique(value.get("loadedSkills"))
        explicit_skills = ordered_unique(value.get("explicitSkills"))
        skill_trace = choose_skill_trace(loaded_skills, explicit_skills)
        serialized_turns.append(
            {
                "turnId": turn_id,
                "date": value["date"],
                "usage": value["usage"],
                "skills": sorted(value["skills"]),
                "skillTrace": skill_trace,
                "explicitSkills": explicit_skills,
                "loadedSkills": loaded_skills,
                "model": value.get("model"),
                "effort": value.get("effort"),
                "cwd": value.get("cwd"),
                "completed": bool(value.get("completed")),
            }
        )

    agent_type = "ROOT" if not meta.get("parent_thread_id") else "SUBAGENT"
    return {
        "threadId": str(meta.get("id") or meta.get("session_id") or path.stem),
        "agent": agent,
        "agentType": agent_type,
        "agentNickname": str(meta.get("agent_nickname") or ""),
        "parentThreadId": str(meta.get("parent_thread_id") or ""),
        "cwd": str(meta.get("cwd") or ""),
        "originator": str(meta.get("originator") or ""),
        "turns": serialized_turns,
        "rateSnapshots": rate_snapshots,
        "skillCatalogs": skill_catalogs,
        "toolCalls": tool_calls,
    }


def load_cache(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        if data.get("version") == CACHE_VERSION and isinstance(data.get("files"), dict):
            return data
    except (OSError, json.JSONDecodeError, TypeError):
        pass
    return {"version": CACHE_VERSION, "files": {}}


def save_cache(path: Path, data: dict[str, Any]) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_suffix(path.suffix + ".tmp")
        temporary.write_text(json.dumps(data, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
        os.replace(temporary, path)
    except OSError:
        pass


def summary_has_any_day(summary: Any, valid_days: set[str]) -> bool:
    if not isinstance(summary, dict):
        return False
    for turn in summary.get("turns") or []:
        if isinstance(turn, dict) and str(turn.get("date") or "") in valid_days:
            return True
    return False


def summary_token_total(summary: Any, valid_days: set[str]) -> int:
    if not isinstance(summary, dict):
        return 0
    total = 0
    for turn in summary.get("turns") or []:
        if not isinstance(turn, dict) or str(turn.get("date") or "") not in valid_days:
            continue
        total += normalize_usage(turn.get("usage"))["total_tokens"]
    return total


def candidate_rollouts(homes: list[Path], cutoff: datetime) -> list[Path]:
    found: dict[str, Path] = {}
    cutoff_ts = cutoff.timestamp()
    for home in homes:
        for folder_name in ("sessions", "archived_sessions"):
            folder = home / folder_name
            if not folder.exists():
                continue
            try:
                iterator = folder.rglob("*.jsonl")
                for path in iterator:
                    try:
                        if path.stat().st_mtime >= cutoff_ts:
                            found[str(path.resolve()).lower()] = path.resolve()
                    except OSError:
                        continue
            except OSError:
                continue
    return sorted(found.values(), key=lambda item: str(item).lower())


def load_runtime_rate_history(path: Path | None) -> list[dict[str, Any]]:
    if path is None or not path.exists():
        return []
    snapshots = []
    try:
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                try:
                    value = json.loads(line)
                    if isinstance(value, dict) and value.get("timestamp") and value.get("usedPercent") is not None:
                        snapshots.append(value)
                except (json.JSONDecodeError, TypeError):
                    continue
    except OSError:
        return []
    return snapshots


def build_rate_daily(snapshots: list[dict[str, Any]], days: list[str]) -> tuple[list[dict[str, Any]], str | None]:
    normalized = []
    for value in snapshots:
        observed = parse_timestamp(value.get("timestamp"))
        if not observed:
            continue
        try:
            normalized.append(
                {
                    "observed": observed,
                    "used": float(value.get("usedPercent")),
                    "reset": int(value.get("resetEpoch")) if value.get("resetEpoch") is not None else None,
                    "window": int(value.get("windowMinutes")) if value.get("windowMinutes") is not None else None,
                    "limit": str(value.get("limitId") or "primary"),
                }
            )
        except (TypeError, ValueError, OverflowError):
            continue

    normalized.sort(key=lambda item: item["observed"])
    daily = {day: 0.0 for day in days}
    previous_by_limit: dict[str, dict[str, Any]] = {}
    for current in normalized:
        day_key = current["observed"].date().isoformat()
        previous = previous_by_limit.get(current["limit"])
        delta = 0.0
        if previous and previous["reset"] == current["reset"]:
            delta = max(0.0, current["used"] - previous["used"])
        elif previous and previous["reset"] != current["reset"]:
            delta = max(0.0, current["used"])
        previous_by_limit[current["limit"]] = current
        if day_key in daily:
            daily[day_key] += delta

    coverage_start = normalized[0]["observed"].isoformat() if normalized else None
    return (
        [{"date": day, "usedPercentDelta": round(daily[day], 3)} for day in days],
        coverage_start,
    )


def aggregate(args: argparse.Namespace) -> dict[str, Any]:
    now = datetime.now().astimezone()
    today = now.date()
    days = [(today - timedelta(days=offset)).isoformat() for offset in range(args.days - 1, -1, -1)]
    valid_days = set(days)
    cutoff = datetime.combine(today - timedelta(days=args.days), datetime.min.time()).astimezone()
    homes = [Path(value).expanduser().resolve() for value in args.codex_home]
    skill_roots = [Path(value).expanduser().resolve() for value in (args.skill_root or [])]
    if not skill_roots:
        skill_roots = [(Path.home() / ".agents" / "skills").resolve()]
    files = candidate_rollouts(homes, cutoff)
    cache_path = Path(args.cache).expanduser().resolve()
    cache = load_cache(cache_path)
    old_entries = cache.get("files", {})
    new_entries: dict[str, Any] = {}
    cache_hits = 0
    parse_errors = 0
    retained_files = 0

    for path in files:
        key = str(path)
        try:
            stat = path.stat()
        except OSError:
            continue
        old = old_entries.get(key)
        if (
            isinstance(old, dict)
            and old.get("size") == stat.st_size
            and old.get("mtimeNs") == stat.st_mtime_ns
            and isinstance(old.get("summary"), dict)
        ):
            entry = old
            cache_hits += 1
        else:
            try:
                summary = parse_rollout(path)
            except OSError:
                parse_errors += 1
                continue
            entry = {"size": stat.st_size, "mtimeNs": stat.st_mtime_ns, "summary": summary}
        new_entries[key] = entry

    # Account re-login can move or temporarily hide rollout files. Preserve cached
    # summaries that still contribute to the active date window; they expire
    # naturally once none of their turns belongs to the requested days.
    for key, old in old_entries.items():
        if key in new_entries or not isinstance(old, dict):
            continue
        summary = old.get("summary")
        if isinstance(summary, dict) and summary_has_any_day(summary, valid_days):
            new_entries[key] = old
            retained_files += 1

    save_cache(cache_path, {"version": CACHE_VERSION, "files": new_entries})

    daily_usage: dict[str, dict[str, int]] = {day: empty_usage() for day in days}
    agent_tokens: defaultdict[str, int] = defaultdict(int)
    skill_primary_tokens: defaultdict[str, int] = defaultdict(int)
    skill_associated_tokens: defaultdict[str, int] = defaultdict(int)
    skill_turns: defaultdict[str, int] = defaultdict(int)
    skill_primary_turns: defaultdict[str, int] = defaultdict(int)
    skill_router_turns: defaultdict[str, int] = defaultdict(int)
    skill_chain_tokens: defaultdict[str, int] = defaultdict(int)
    skill_chain_turns: defaultdict[str, int] = defaultdict(int)
    skill_last_used: dict[str, str] = {}
    all_rate_snapshots: list[dict[str, Any]] = []
    local_total = 0
    attributed_skill_total = 0
    unattributed_skill_tokens = 0

    # A rollout may move from sessions to archived_sessions without changing its
    # filename. Deduplicate that moved file, but do not deduplicate by thread ID:
    # one long thread can legitimately span multiple rollout files after resume
    # or context compaction, and every segment contributes new token deltas.
    summaries_by_rollout: dict[str, tuple[tuple[int, int, int], dict[str, Any]]] = {}
    for cache_key, entry in new_entries.items():
        summary = entry["summary"]
        rollout_id = Path(cache_key).name.lower()
        rank = (
            summary_token_total(summary, valid_days),
            int(entry.get("size", 0) or 0),
            int(entry.get("mtimeNs", 0) or 0),
        )
        previous = summaries_by_rollout.get(rollout_id)
        if previous is None or rank > previous[0]:
            summaries_by_rollout[rollout_id] = (rank, summary)

    latest_catalog_entries: list[dict[str, str]] = []
    latest_catalog_timestamp: str | None = None
    latest_catalog_rank = float("-inf")
    for _, summary in summaries_by_rollout.values():
        for catalog in summary.get("skillCatalogs") or []:
            if not isinstance(catalog, dict) or not isinstance(catalog.get("entries"), list):
                continue
            observed = parse_timestamp(catalog.get("timestamp"))
            rank = observed.timestamp() if observed else 0.0
            if rank >= latest_catalog_rank:
                latest_catalog_rank = rank
                latest_catalog_timestamp = catalog.get("timestamp")
                latest_catalog_entries = catalog["entries"]

    catalog_names: dict[str, str] = {}
    aliases: dict[str, str] = {}
    scope_by_name: dict[str, str] = {}
    installed_keys: set[str] = set()
    for entry in latest_catalog_entries:
        name = normalize_skill_name(entry.get("name"))
        if not name:
            continue
        key = name.lower()
        catalog_names[key] = name
        aliases[key] = name
        scope_by_name[key] = str(entry.get("scope") or "OTHER")
        skill_path = str(entry.get("path") or "")
        if skill_path:
            folder_name = Path(skill_path.replace("\\", "/")).parent.name
            if folder_name:
                aliases.setdefault(folder_name.lower(), name)
            try:
                if Path(skill_path).is_file():
                    installed_keys.add(key)
            except OSError:
                pass

    def canonical_skill_name(name: str) -> str:
        return aliases.get(name.lower(), name)

    inventory_names: dict[str, str] = dict(catalog_names)
    for root in skill_roots:
        for installed_name in discover_installed_skills([root]):
            canonical = canonical_skill_name(installed_name)
            key = canonical.lower()
            inventory_names.setdefault(key, canonical)
            installed_keys.add(key)
            scope_by_name.setdefault(
                key,
                classify_skill_scope(str(root / installed_name / "SKILL.md")),
            )

    agent_breakdown: dict[str, dict[str, Any]] = {}
    agent_kind_tokens: defaultdict[str, int] = defaultdict(int)
    tool_categories: dict[str, dict[str, Any]] = {}
    turn_tool_stats: defaultdict[tuple[str, str], dict[str, int]] = defaultdict(
        lambda: {"calls": 0, "failures": 0}
    )

    for _, summary in summaries_by_rollout.values():
        agent = str(summary.get("agent") or "ROOT")
        agent_type = str(summary.get("agentType") or ("ROOT" if agent == "ROOT" else "SUBAGENT"))
        thread_id = str(summary.get("threadId") or "")
        all_rate_snapshots.extend(summary.get("rateSnapshots") or [])

        for call in summary.get("toolCalls") or []:
            if not isinstance(call, dict) or call.get("date") not in valid_days:
                continue
            tool_name = str(call.get("tool") or "other")
            category = str(call.get("category") or classify_tool(tool_name))
            detail = tool_categories.setdefault(
                category,
                {"calls": 0, "failures": 0, "tools": set(), "lastUsed": None},
            )
            detail["calls"] += 1
            detail["tools"].add(tool_name)
            call_date = str(call.get("date") or "")
            if call_date and (not detail["lastUsed"] or call_date > detail["lastUsed"]):
                detail["lastUsed"] = call_date
            stats = turn_tool_stats[(thread_id, str(call.get("turnId") or "unattributed-turn"))]
            stats["calls"] += 1
            if call.get("status") == "failed":
                detail["failures"] += 1
                stats["failures"] += 1

        for turn in summary.get("turns") or []:
            day_key = turn.get("date")
            usage = normalize_usage(turn.get("usage"))
            tokens = usage["total_tokens"]
            if day_key not in daily_usage or tokens <= 0:
                continue
            add_usage(daily_usage[day_key], usage)
            local_total += tokens
            agent_tokens[agent] += tokens
            agent_kind_tokens[agent_type] += tokens

            cwd = str(turn.get("cwd") or summary.get("cwd") or "")
            if agent_type == "ROOT":
                project = Path(cwd).name if cwd else "未命名项目"
                breakdown_key = f"ROOT::{cwd.lower()}"
                breakdown_name = project or cwd or "未命名项目"
            else:
                breakdown_key = f"SUBAGENT::{agent.lower()}"
                breakdown_name = agent
            detail = agent_breakdown.setdefault(
                breakdown_key,
                {
                    "name": breakdown_name,
                    "kind": agent_type,
                    "tokens": 0,
                    "turns": 0,
                    "sessions": set(),
                    "completedSessions": set(),
                    "completedTurns": 0,
                    "toolCalls": 0,
                    "toolFailures": 0,
                    "lastUsed": None,
                    "models": set(),
                    "efforts": set(),
                    "sources": set(),
                },
            )
            detail["tokens"] += tokens
            detail["turns"] += 1
            tool_stats = turn_tool_stats[(thread_id, str(turn.get("turnId") or "unattributed-turn"))]
            detail["toolCalls"] += tool_stats["calls"]
            detail["toolFailures"] += tool_stats["failures"]
            if turn.get("completed"):
                detail["completedTurns"] += 1
                if thread_id:
                    detail["completedSessions"].add(thread_id)
            if day_key and (not detail["lastUsed"] or day_key > detail["lastUsed"]):
                detail["lastUsed"] = day_key
            if thread_id:
                detail["sessions"].add(thread_id)
            if turn.get("model"):
                detail["models"].add(str(turn["model"]))
            if turn.get("effort"):
                detail["efforts"].add(str(turn["effort"]))
            if summary.get("originator"):
                detail["sources"].add(str(summary["originator"]))

            trace_source = turn.get("skillTrace") if "skillTrace" in turn else turn.get("skills")
            trace = [canonical_skill_name(name) for name in ordered_unique(trace_source or [])]
            trace = ordered_unique(trace)
            if not trace:
                unattributed_skill_tokens += tokens
                continue

            attributed_skill_total += tokens
            for skill_name in trace:
                key = skill_name.lower()
                inventory_names.setdefault(key, skill_name)
                scope_by_name.setdefault(key, "OBSERVED")
                skill_associated_tokens[skill_name] += tokens
                skill_turns[skill_name] += 1
                if day_key and (skill_name not in skill_last_used or day_key > skill_last_used[skill_name]):
                    skill_last_used[skill_name] = day_key

            primary_skill = choose_primary_skill(trace)
            if primary_skill:
                skill_primary_tokens[primary_skill] += tokens
                skill_primary_turns[primary_skill] += 1

            if len(trace) > 1:
                chain_name = " \u2192 ".join(trace)
                skill_chain_tokens[chain_name] += tokens
                skill_chain_turns[chain_name] += 1
                for routing_skill in trace[:-1]:
                    skill_router_turns[routing_skill] += 1

    daily_rows = []
    for day_key in days:
        usage = daily_usage[day_key]
        daily_rows.append(
            {
                "date": day_key,
                "tokens": usage["total_tokens"],
                "inputTokens": usage["input_tokens"],
                "cachedInputTokens": usage["cached_input_tokens"],
                "outputTokens": usage["output_tokens"],
                "reasoningOutputTokens": usage["reasoning_output_tokens"],
                "sharePercent": round((usage["total_tokens"] / local_total * 100.0), 2) if local_total else 0.0,
            }
        )

    def category_rows(values: dict[str, int]) -> list[dict[str, Any]]:
        total = sum(values.values())
        return [
            {
                "name": name,
                "tokens": tokens,
                "sharePercent": round(tokens / total * 100.0, 2) if total else 0.0,
            }
            for name, tokens in sorted(values.items(), key=lambda item: (-item[1], item[0].lower()))
        ]

    skill_rows = []
    available_keys = set(catalog_names)
    for name in inventory_names.values():
        primary_tokens = skill_primary_tokens[name]
        associated_tokens = skill_associated_tokens[name]
        turns = skill_turns[name]
        installed = name.lower() in installed_keys
        available = name.lower() in available_keys
        if turns >= 3:
            status = "frequent"
        elif turns > 0:
            status = "occasional"
        elif installed and not available:
            status = "installed_only"
        else:
            status = "unused"
        skill_rows.append(
            {
                "name": name,
                "tokens": associated_tokens,
                "sharePercent": round(associated_tokens / local_total * 100.0, 2) if local_total else 0.0,
                "associatedTokens": associated_tokens,
                "associatedSharePercent": round(associated_tokens / local_total * 100.0, 2) if local_total else 0.0,
                "primaryTokens": primary_tokens,
                "primarySharePercent": round(primary_tokens / local_total * 100.0, 2) if local_total else 0.0,
                "turns": turns,
                "primaryTurns": skill_primary_turns[name],
                "routerTurns": skill_router_turns[name],
                "installed": installed,
                "available": available,
                "scope": scope_by_name.get(name.lower(), "OTHER"),
                "status": status,
                "lastUsed": skill_last_used.get(name),
            }
        )
    skill_rows.sort(
        key=lambda item: (
            -int(item["tokens"]),
            -int(item["primaryTokens"]),
            0 if item["available"] else 1,
            0 if item["installed"] else 1,
            str(item["name"]).lower(),
        )
    )

    skill_chain_rows = [
        {
            "name": name,
            "tokens": tokens,
            "sharePercent": round(tokens / local_total * 100.0, 2) if local_total else 0.0,
            "turns": skill_chain_turns[name],
        }
        for name, tokens in sorted(skill_chain_tokens.items(), key=lambda item: (-item[1], item[0].lower()))
    ]

    agent_breakdown_rows = []
    for value in agent_breakdown.values():
        agent_breakdown_rows.append(
            {
                "name": value["name"],
                "kind": value["kind"],
                "tokens": value["tokens"],
                "sharePercent": round(value["tokens"] / local_total * 100.0, 2) if local_total else 0.0,
                "turns": value["turns"],
                "sessions": len(value["sessions"]),
                "completedTurns": value["completedTurns"],
                "completedSessions": len(value["completedSessions"]),
                "toolCalls": value["toolCalls"],
                "toolFailures": value["toolFailures"],
                "lastUsed": value["lastUsed"],
                "models": sorted(value["models"]),
                "efforts": sorted(value["efforts"]),
                "sources": sorted(value["sources"]),
            }
        )
    agent_breakdown_rows.sort(
        key=lambda item: (0 if item["kind"] == "ROOT" else 1, -int(item["tokens"]), str(item["name"]).lower())
    )

    config_paths: dict[str, Path] = {}
    raw_config_paths = getattr(args, "codex_config", None) or []
    if isinstance(raw_config_paths, str):
        raw_config_paths = [raw_config_paths]
    for value in raw_config_paths:
        path = Path(value).expanduser().resolve()
        config_paths[str(path).lower()] = path
    for _, summary in summaries_by_rollout.values():
        cwd = str(summary.get("cwd") or "")
        if cwd:
            project_config = (Path(cwd) / ".codex" / "config.toml").resolve()
            if project_config.is_file():
                config_paths[str(project_config).lower()] = project_config

    configured_mcp: dict[str, bool] = {}
    configured_plugins: dict[str, bool] = {}
    configured_plugin_mcp: dict[str, bool] = {}
    for config_path in config_paths.values():
        parsed_config = parse_codex_config(config_path)
        prefix = str(config_path.parent)
        for name, enabled in parsed_config["mcpServers"].items():
            configured_mcp[f"{prefix}::{name}"] = enabled
        for name, enabled in parsed_config["plugins"].items():
            configured_plugins[name] = enabled
        for name, enabled in parsed_config["pluginMcpServers"].items():
            configured_plugin_mcp[name] = enabled

    total_tool_calls = sum(int(value["calls"]) for value in tool_categories.values())
    tool_order = {name: index for index, name in enumerate((
        "command", "file", "web", "connector", "agent", "document", "media", "workflow", "other"
    ))}
    tool_rows = [
        {
            "name": category,
            "category": category,
            "calls": int(value["calls"]),
            "failures": int(value["failures"]),
            "sharePercent": round(int(value["calls"]) / total_tool_calls * 100.0, 2) if total_tool_calls else 0.0,
            "lastUsed": value["lastUsed"],
            "tools": sorted(value["tools"], key=str.lower),
        }
        for category, value in sorted(
            tool_categories.items(),
            key=lambda item: (-int(item[1]["calls"]), tool_order.get(item[0], 99), item[0]),
        )
    ]

    rate_history_path = Path(args.rate_history).expanduser().resolve() if args.rate_history else None
    all_rate_snapshots.extend(load_runtime_rate_history(rate_history_path))
    rate_daily, rate_coverage_start = build_rate_daily(all_rate_snapshots, days)

    workflow_hints: list[str] = []
    total_tool_failures = sum(int(value["failures"]) for value in tool_categories.values())
    unused_skill_count = sum(1 for row in skill_rows if row["status"] in {"unused", "installed_only"})
    enabled_integration_count = (
        sum(1 for enabled in configured_mcp.values() if enabled)
        + sum(1 for enabled in configured_plugin_mcp.values() if enabled)
        + sum(1 for enabled in configured_plugins.values() if enabled)
    )
    connector_calls = int(tool_categories.get("connector", {}).get("calls", 0))
    if total_tool_failures:
        workflow_hints.append(f"近 {args.days} 日有 {total_tool_failures} 次工具调用失败，可在 Tool 页查看类别。")
    if unused_skill_count:
        workflow_hints.append(f"发现 {unused_skill_count} 个 Skill 近 {args.days} 日没有使用。")
    if enabled_integration_count and connector_calls == 0:
        workflow_hints.append(
            f"已启用 {enabled_integration_count} 个 MCP/插件配置，但近 {args.days} 日未观察到连接器调用。"
        )
    if len(workflow_hints) < 3 and local_total and attributed_skill_total / local_total < 0.5:
        workflow_hints.append(
            f"有 {unattributed_skill_tokens / local_total * 100.0:.1f}% 的本地 Token 无法归因到 Skill。"
        )

    return {
        "generatedAt": now.isoformat(),
        "days": args.days,
        "scannedFiles": len(new_entries),
        "cacheHits": cache_hits,
        "retainedFiles": retained_files,
        "uniqueRollouts": len(summaries_by_rollout),
        "parseErrors": parse_errors,
        "localTotalTokens": local_total,
        "daily": daily_rows,
        "agents": category_rows(agent_tokens),
        "agentSummary": category_rows(agent_kind_tokens),
        "agentBreakdown": agent_breakdown_rows,
        "skills": skill_rows,
        "externalSkills": [row for row in skill_rows if not row["installed"]],
        "skillChains": skill_chain_rows,
        "installedSkillCount": sum(1 for row in skill_rows if row["installed"]),
        "availableSkillCount": len(available_keys) if available_keys else len(installed_keys),
        "skillCatalogObservedAt": latest_catalog_timestamp,
        "unattributedSkillTokens": unattributed_skill_tokens,
        "unattributedSkillPercent": round(unattributed_skill_tokens / local_total * 100.0, 2) if local_total else 0.0,
        "skillCoveragePercent": round(attributed_skill_total / local_total * 100.0, 2) if local_total else 0.0,
        "skillAttributionVersion": 4,
        "tools": {
            "calls": total_tool_calls,
            "failures": total_tool_failures,
            "rows": tool_rows,
            "configuredMcpServers": len(configured_mcp),
            "enabledMcpServers": sum(1 for enabled in configured_mcp.values() if enabled),
            "configuredPluginServers": len(configured_plugin_mcp),
            "enabledPluginServers": sum(1 for enabled in configured_plugin_mcp.values() if enabled),
            "plugins": len(configured_plugins),
            "enabledPlugins": sum(1 for enabled in configured_plugins.values() if enabled),
            "configFiles": len(config_paths),
        },
        "workflowHints": workflow_hints[:3],
        "rateDaily": rate_daily,
        "rateCoverageStart": rate_coverage_start,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--codex-home", action="append", required=True)
    parser.add_argument("--skill-root", action="append")
    parser.add_argument("--codex-config", action="append")
    parser.add_argument("--cache", required=True)
    parser.add_argument("--rate-history")
    parser.add_argument("--days", type=int, default=7)
    args = parser.parse_args()
    if args.days < 1 or args.days > 31:
        parser.error("--days must be between 1 and 31")
    try:
        result = aggregate(args)
    except Exception as exc:  # Keep the widget alive and return a compact failure.
        print(json.dumps({"error": f"{type(exc).__name__}: {exc}"}, ensure_ascii=True))
        return 1
    print(json.dumps(result, ensure_ascii=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
