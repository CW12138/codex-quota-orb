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
    def test_trace_selection_keeps_long_genuine_chains(self) -> None:
        self.assertEqual(
            analytics.choose_skill_trace(["task-router", "data-analysis"], []),
            ["task-router", "data-analysis"],
        )
        self.assertEqual(
            analytics.choose_skill_trace([], list(CANONICAL_SKILLS)),
            list(CANONICAL_SKILLS),
        )
        self.assertEqual(analytics.choose_primary_skill(["task-router", "data-analysis"]), "data-analysis")
        self.assertEqual(analytics.extract_explicit_skills("$env:PATH $testing"), ["testing"])

    def test_available_inventory_repeated_tokens_agents_tools_and_route_chain(self) -> None:
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
                {
                    "timestamp": now,
                    "type": "session_meta",
                    "payload": {"id": "thread-1", "cwd": str(root / "project"), "originator": "codex-tui"},
                },
                {
                    "timestamp": now,
                    "type": "response_item",
                    "payload": {
                        "type": "message",
                        "role": "developer",
                        "content": [
                            {
                                "type": "input_text",
                                "text": (
                                    "<skills_instructions>\n### Available skills\n"
                                    f"- task-router: Route tasks. (file: {skill_root / 'task-router' / 'SKILL.md'})\n"
                                    f"- plugin:data-analysis: Analyze data. (file: {skill_root / 'data-analysis' / 'SKILL.md'})\n"
                                    "</skills_instructions>"
                                ),
                            }
                        ],
                    },
                },
                {
                    "timestamp": now,
                    "type": "turn_context",
                    "payload": {"turn_id": "turn-1", "model": "gpt-test", "effort": "high"},
                },
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
                    "type": "response_item",
                    "payload": {
                        "type": "custom_tool_call",
                        "name": "exec",
                        "call_id": "exec-1",
                        "input": "await tools.web__run({}); await tools.apply_patch('patch')",
                    },
                },
                {
                    "timestamp": now,
                    "type": "response_item",
                    "payload": {"type": "custom_tool_call_output", "call_id": "exec-1", "output": "ok"},
                },
                {
                    "timestamp": now,
                    "type": "response_item",
                    "payload": {"type": "function_call", "name": "mcp__docs__search", "call_id": "mcp-1", "arguments": "{}"},
                },
                {
                    "timestamp": now,
                    "type": "response_item",
                    "payload": {"type": "function_call_output", "call_id": "mcp-1", "output": "ok"},
                },
                {
                    "timestamp": now,
                    "type": "response_item",
                    "payload": {
                        "type": "custom_tool_call",
                        "name": "exec",
                        "call_id": "exec-failed",
                        "input": "await tools.exec_command({})",
                    },
                },
                {
                    "timestamp": now,
                    "type": "response_item",
                    "payload": {
                        "type": "custom_tool_call_output",
                        "call_id": "exec-failed",
                        "output": "Script failed\nWall time 0.1 seconds",
                    },
                },
                {
                    "timestamp": now,
                    "type": "response_item",
                    "payload": {"type": "message", "role": "assistant", "phase": "final_answer", "content": []},
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

            config = root / "config.toml"
            config.write_text(
                '[mcp_servers.docs]\ncommand = "docs"\n\n[plugins."documents@test"]\nenabled = true\n',
                encoding="utf-8",
            )

            args = argparse.Namespace(
                codex_home=[str(codex_home)],
                skill_root=[str(skill_root)],
                codex_config=[str(config)],
                cache=str(root / "cache.json"),
                rate_history=None,
                days=7,
            )
            result = analytics.aggregate(args)

            rows = {row["name"]: row for row in result["skills"]}
            self.assertEqual(result["installedSkillCount"], 12)
            self.assertEqual(len(result["skills"]), 12)
            self.assertEqual(result["availableSkillCount"], 2)
            self.assertEqual(rows["plugin:data-analysis"]["tokens"], 100)
            self.assertEqual(rows["plugin:data-analysis"]["primaryTokens"], 100)
            self.assertEqual(rows["task-router"]["tokens"], 100)
            self.assertEqual(rows["task-router"]["primaryTokens"], 0)
            self.assertEqual(rows["task-router"]["associatedTokens"], 100)
            self.assertEqual(rows["task-router"]["routerTurns"], 1)
            self.assertEqual(result["unattributedSkillTokens"], 50)
            self.assertEqual(sum(row["tokens"] for row in result["skills"]), 200)
            self.assertEqual(result["skillChains"][0]["name"], "task-router → plugin:data-analysis")
            self.assertEqual(result["skillChains"][0]["tokens"], 100)
            self.assertEqual(result["agentBreakdown"][0]["name"], "project")
            self.assertEqual(result["agentBreakdown"][0]["models"], ["gpt-test"])
            self.assertEqual(result["agentBreakdown"][0]["completedTurns"], 1)
            self.assertEqual(result["agentBreakdown"][0]["toolCalls"], 4)
            self.assertEqual(result["agentBreakdown"][0]["toolFailures"], 1)
            self.assertEqual(rows["task-router"]["status"], "occasional")
            self.assertEqual(rows["task-router"]["lastUsed"], datetime.now().astimezone().date().isoformat())
            self.assertEqual(result["tools"]["configuredMcpServers"], 1)
            self.assertEqual(result["tools"]["enabledPlugins"], 1)
            self.assertEqual(result["tools"]["calls"], 4)
            self.assertEqual(result["tools"]["failures"], 1)
            tool_rows = {row["category"]: row for row in result["tools"]["rows"]}
            self.assertEqual(tool_rows["web"]["calls"], 1)
            self.assertEqual(tool_rows["file"]["calls"], 1)
            self.assertEqual(tool_rows["connector"]["calls"], 1)
            self.assertEqual(tool_rows["command"]["calls"], 1)
            self.assertEqual(tool_rows["command"]["failures"], 1)
            self.assertLessEqual(len(result["workflowHints"]), 3)

    def test_analytics_has_no_network_or_model_client(self) -> None:
        source = Path(analytics.__file__).read_text(encoding="utf-8")
        for forbidden in ("requests.", "urllib.request", "openai.", "subprocess."):
            self.assertNotIn(forbidden, source)


if __name__ == "__main__":
    unittest.main()
