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


CACHE_VERSION = 4
TOKEN_KEYS = (
    "total_tokens",
    "input_tokens",
    "cached_input_tokens",
    "output_tokens",
    "reasoning_output_tokens",
)
SKILL_PATH_RE = re.compile(r"[\\/]([^\\/\"']+)[\\/]SKILL\.md", re.IGNORECASE)
EXPLICIT_SKILL_RE = re.compile(r"(?<![\w-])\$([A-Za-z0-9_.:-]+)")


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


def extract_skills_from_tool_input(value: Any) -> set[str]:
    if not isinstance(value, str) or "SKILL.MD" not in value.upper():
        return set()
    return {match.group(1) for match in SKILL_PATH_RE.finditer(value)}


def extract_explicit_skills(value: Any) -> set[str]:
    if not isinstance(value, str):
        return set()
    return {match.group(1) for match in EXPLICIT_SKILL_RE.finditer(value)}


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
            {"date": None, "usage": empty_usage(), "skills": set()},
        )

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
                get_turn(current_turn)["skills"].update(extract_explicit_skills(message))

            if top_type == "response_item" and payload.get("type") in {
                "custom_tool_call",
                "function_call",
            }:
                tool_input = payload.get("input")
                if tool_input is None:
                    tool_input = payload.get("arguments")
                get_turn(current_turn)["skills"].update(extract_skills_from_tool_input(tool_input))

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
        serialized_turns.append(
            {
                "turnId": turn_id,
                "date": value["date"],
                "usage": value["usage"],
                "skills": sorted(value["skills"]),
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
    skill_tokens: defaultdict[str, int] = defaultdict(int)
    all_rate_snapshots: list[dict[str, Any]] = []
    local_total = 0
    attributed_skill_total = 0

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
            skills = [str(value) for value in (turn.get("skills") or []) if str(value).strip()]
            if len(skills) == 1:
                skill_label = skills[0]
                attributed_skill_total += tokens
            elif len(skills) > 1:
                skill_label = "MULTI_SKILL"
                attributed_skill_total += tokens
            else:
                skill_label = "UNATTRIBUTED"
            skill_tokens[skill_label] += tokens

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
        "skills": category_rows(skill_tokens),
        "skillCoveragePercent": round(attributed_skill_total / local_total * 100.0, 2) if local_total else 0.0,
        "rateDaily": rate_daily,
        "rateCoverageStart": rate_coverage_start,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--codex-home", action="append", required=True)
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
