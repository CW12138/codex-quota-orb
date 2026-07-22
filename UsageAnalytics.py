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


CACHE_VERSION = 6
TOKEN_KEYS = (
    "total_tokens",
    "input_tokens",
    "cached_input_tokens",
    "output_tokens",
    "reasoning_output_tokens",
)
SKILL_PATH_RE = re.compile(r"[\\/]([^\\/\"']+)[\\/]SKILL\.md", re.IGNORECASE)
EXPLICIT_SKILL_RE = re.compile(r"(?<![\w-])\$([A-Za-z0-9_.:-]+)")
POWERSHELL_SCOPE_PREFIXES = ("env:", "global:", "local:", "private:", "script:")
ROUTER_SKILLS = {"meisi"}
MAX_SKILL_TRACE_LENGTH = 3


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


def choose_primary_skill(trace: list[str]) -> str | None:
    if not trace:
        return None
    non_router = [name for name in trace if name.lower() not in ROUTER_SKILLS]
    return non_router[-1] if non_router else trace[-1]


def choose_skill_trace(loaded_skills: Any, explicit_skills: Any) -> list[str]:
    """Prefer ordered file-load evidence and reject bulk catalog references."""
    for candidate in (ordered_unique(loaded_skills), ordered_unique(explicit_skills)):
        if 0 < len(candidate) <= MAX_SKILL_TRACE_LENGTH:
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
                continue

            if top_type == "event_msg" and payload.get("type") == "user_message":
                message = payload.get("message")
                if message is None:
                    message = payload.get("text")
                add_skill_evidence(current_turn, extract_explicit_skills(message), "explicit")

            if top_type == "response_item" and payload.get("type") in {
                "custom_tool_call",
                "function_call",
            }:
                tool_input = payload.get("input")
                if tool_input is None:
                    tool_input = payload.get("arguments")
                add_skill_evidence(current_turn, extract_skills_from_tool_input(tool_input), "loaded")

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
            }
        )

    return {
        "threadId": str(meta.get("id") or meta.get("session_id") or path.stem),
        "agent": agent,
        "turns": serialized_turns,
        "rateSnapshots": rate_snapshots,
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
    installed_skills = discover_installed_skills(skill_roots)
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

    for _, summary in summaries_by_rollout.values():
        agent = str(summary.get("agent") or "ROOT")
        all_rate_snapshots.extend(summary.get("rateSnapshots") or [])
        for turn in summary.get("turns") or []:
            day_key = turn.get("date")
            usage = normalize_usage(turn.get("usage"))
            tokens = usage["total_tokens"]
            if day_key not in daily_usage or tokens <= 0:
                continue
            add_usage(daily_usage[day_key], usage)
            local_total += tokens
            agent_tokens[agent] += tokens
            trace_source = turn.get("skillTrace") if "skillTrace" in turn else turn.get("skills")
            trace = ordered_unique(trace_source or [])
            if not trace:
                unattributed_skill_tokens += tokens
                continue

            attributed_skill_total += tokens
            for skill_name in trace:
                skill_associated_tokens[skill_name] += tokens
                skill_turns[skill_name] += 1

            primary_skill = choose_primary_skill(trace)
            if primary_skill:
                skill_primary_tokens[primary_skill] += tokens
                skill_primary_turns[primary_skill] += 1

            if len(trace) > 1:
                chain_name = " \u2192 ".join(trace)
                skill_chain_tokens[chain_name] += tokens
                skill_chain_turns[chain_name] += 1
                if trace[0].lower() in ROUTER_SKILLS:
                    skill_router_turns[trace[0]] += 1

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

    known_skill_names: dict[str, str] = {name.lower(): name for name in installed_skills}
    for collection in (skill_primary_tokens, skill_associated_tokens):
        for name in collection:
            known_skill_names.setdefault(name.lower(), name)

    skill_rows = []
    installed_keys = {name.lower() for name in installed_skills}
    main_skill_names = installed_skills or list(known_skill_names.values())
    for name in main_skill_names:
        primary_tokens = skill_primary_tokens[name]
        associated_tokens = skill_associated_tokens[name]
        skill_rows.append(
            {
                "name": name,
                "tokens": primary_tokens,
                "sharePercent": round(primary_tokens / local_total * 100.0, 2) if local_total else 0.0,
                "associatedTokens": associated_tokens,
                "associatedSharePercent": round(associated_tokens / local_total * 100.0, 2) if local_total else 0.0,
                "turns": skill_turns[name],
                "primaryTurns": skill_primary_turns[name],
                "routerTurns": skill_router_turns[name],
                "installed": name.lower() in installed_keys,
            }
        )
    skill_rows.sort(
        key=lambda item: (
            -int(item["tokens"]),
            -int(item["associatedTokens"]),
            0 if item["installed"] else 1,
            str(item["name"]).lower(),
        )
    )

    external_skill_rows = []
    for name in known_skill_names.values():
        if name.lower() in installed_keys:
            continue
        external_skill_rows.append(
            {
                "name": name,
                "tokens": skill_primary_tokens[name],
                "sharePercent": round(skill_primary_tokens[name] / local_total * 100.0, 2) if local_total else 0.0,
                "associatedTokens": skill_associated_tokens[name],
                "associatedSharePercent": round(skill_associated_tokens[name] / local_total * 100.0, 2) if local_total else 0.0,
                "turns": skill_turns[name],
                "primaryTurns": skill_primary_turns[name],
                "routerTurns": skill_router_turns[name],
                "installed": False,
            }
        )
    external_skill_rows.sort(key=lambda item: (-int(item["tokens"]), -int(item["associatedTokens"]), str(item["name"]).lower()))

    skill_chain_rows = [
        {
            "name": name,
            "tokens": tokens,
            "sharePercent": round(tokens / local_total * 100.0, 2) if local_total else 0.0,
            "turns": skill_chain_turns[name],
        }
        for name, tokens in sorted(skill_chain_tokens.items(), key=lambda item: (-item[1], item[0].lower()))
    ]

    rate_history_path = Path(args.rate_history).expanduser().resolve() if args.rate_history else None
    all_rate_snapshots.extend(load_runtime_rate_history(rate_history_path))
    rate_daily, rate_coverage_start = build_rate_daily(all_rate_snapshots, days)

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
        "skills": skill_rows,
        "externalSkills": external_skill_rows,
        "skillChains": skill_chain_rows,
        "installedSkillCount": len(installed_skills),
        "unattributedSkillTokens": unattributed_skill_tokens,
        "unattributedSkillPercent": round(unattributed_skill_tokens / local_total * 100.0, 2) if local_total else 0.0,
        "skillCoveragePercent": round(attributed_skill_total / local_total * 100.0, 2) if local_total else 0.0,
        "skillAttributionVersion": 2,
        "rateDaily": rate_daily,
        "rateCoverageStart": rate_coverage_start,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--codex-home", action="append", required=True)
    parser.add_argument("--skill-root", action="append")
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
