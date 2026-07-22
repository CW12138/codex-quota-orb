import argparse
import json
import tempfile
import unittest
from datetime import datetime
from pathlib import Path

import UsageAnalytics as analytics


CANONICAL_SKILLS = (
    "task-router",
    "data-analysis",
    "code-review",
    "documentation",
    "image-tools",
    "issue-triage",
    "planning",
    "presentations",
    "release-notes",
    "spreadsheets",
    "testing",
    "web-research",
)


class UsageAnalyticsTests(unittest.TestCase):
    def test_trace_selection_rejects_bulk_catalogs(self) -> None:
        self.assertEqual(
            analytics.choose_skill_trace(["task-router", "data-analysis"], []),
            ["task-router", "data-analysis"],
        )
        self.assertEqual(
            analytics.choose_skill_trace([], list(CANONICAL_SKILLS)),
            [],
        )
        self.assertEqual(analytics.choose_primary_skill(["task-router", "data-analysis"]), "data-analysis")
        self.assertEqual(analytics.extract_explicit_skills("$env:PATH $testing"), ["testing"])

    def test_installed_inventory_primary_tokens_and_route_chain(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            skill_root = root / "skills"
            for name in CANONICAL_SKILLS:
                folder = skill_root / name
                folder.mkdir(parents=True)
                (folder / "SKILL.md").write_text(f"# {name}\n", encoding="utf-8")

            codex_home = root / "codex"
            session_dir = codex_home / "sessions"
            session_dir.mkdir(parents=True)
            now = datetime.now().astimezone().isoformat()
            records = [
                {"timestamp": now, "type": "session_meta", "payload": {"id": "thread-1"}},
                {"timestamp": now, "type": "turn_context", "payload": {"turn_id": "turn-1"}},
                {
                    "timestamp": now,
                    "type": "response_item",
                    "payload": {
                        "type": "function_call",
                        "arguments": "Get-Content C:\\skills\\task-router\\SKILL.md; Get-Content C:\\skills\\data-analysis\\SKILL.md",
                    },
                },
                {
                    "timestamp": now,
                    "type": "event_msg",
                    "payload": {"type": "token_count", "info": {"total_token_usage": {"total_tokens": 100}}},
                },
                {"timestamp": now, "type": "turn_context", "payload": {"turn_id": "turn-2"}},
                {
                    "timestamp": now,
                    "type": "event_msg",
                    "payload": {"type": "token_count", "info": {"total_token_usage": {"total_tokens": 150}}},
                },
            ]
            rollout = session_dir / "rollout-test.jsonl"
            rollout.write_text("\n".join(json.dumps(record) for record in records) + "\n", encoding="utf-8")

            args = argparse.Namespace(
                codex_home=[str(codex_home)],
                skill_root=[str(skill_root)],
                cache=str(root / "cache.json"),
                rate_history=None,
                days=7,
            )
            result = analytics.aggregate(args)

            rows = {row["name"]: row for row in result["skills"]}
            self.assertEqual(result["installedSkillCount"], 12)
            self.assertEqual(len(result["skills"]), 12)
            self.assertEqual(rows["data-analysis"]["tokens"], 100)
            self.assertEqual(rows["data-analysis"]["associatedTokens"], 100)
            self.assertEqual(rows["task-router"]["tokens"], 0)
            self.assertEqual(rows["task-router"]["associatedTokens"], 100)
            self.assertEqual(rows["task-router"]["routerTurns"], 1)
            self.assertEqual(result["unattributedSkillTokens"], 50)
            self.assertEqual(sum(row["tokens"] for row in result["skills"]), 100)
            self.assertEqual(result["skillChains"][0]["name"], "task-router → data-analysis")
            self.assertEqual(result["skillChains"][0]["tokens"], 100)


if __name__ == "__main__":
    unittest.main()
