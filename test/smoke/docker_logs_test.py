"""Regression coverage for Compose log selection and failure suggestions."""

import contextlib
import importlib.util
import io
import json
import sys
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("docker_logs", ROOT / "libexec/makevn/docker/logs.py")
LOGS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(LOGS)


def record(name="app", state="exited", health="none", replica="1"):
    return {"Id": name + replica, "Name": name + "-" + replica,
            "Config": {"Labels": {
                "com.docker.compose.project.working_dir": "/repo",
                "com.docker.compose.project.config_files": "/repo/compose.yml",
                "com.docker.compose.service": name}},
            "State": {"Status": state, "Health": {"Status": health}}}


class DockerLogsTest(unittest.TestCase):
    def args(self, **values):
        return SimpleNamespace(repo="/repo", compose="boot", file="/repo/compose.yml", service=[], tail=100, **values)

    def test_read_stopped_and_running_replicas_without_mutation(self):
        records = [record(), record(state="running", replica="2")]
        commands = []
        def run(command, *, merge_streams):
            self.assertTrue(merge_streams)
            commands.append(command)
            return SimpleNamespace(returncode=0, stdout="failure detail\n", stderr="")
        output = io.StringIO()
        with patch.object(LOGS, "run", run), contextlib.redirect_stdout(output):
            self.assertEqual(LOGS.show_logs(self.args(), ["app"], records), 0)
        self.assertIn("[app/app-1]", output.getvalue())
        self.assertIn("[app/app-2]", output.getvalue())
        self.assertEqual(commands, [
            ["docker", "logs", "--tail", "100", "app1"],
            ["docker", "logs", "--tail", "100", "app2"]])

    def test_suggestion_targets_all_failed_services_for_both_stacks(self):
        for stack in ("boot", "karate"):
            args = self.args()
            args.compose = stack
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                LOGS.suggest(args, [record(), record("db", "running", "unhealthy"),
                                    record("healthy", "running")])
            suggestion = json.loads(output.getvalue().split("MCP docker_logs arguments: ")[1])
            self.assertEqual(suggestion, {"repo": "/repo", "compose": stack,
                                         "services": ["app", "db"], "compose-file": "/repo/compose.yml"})

    def test_ownership_rejects_another_worktree_before_reading_logs(self):
        foreign = record()
        foreign["Config"]["Labels"]["com.docker.compose.project.working_dir"] = "/other"
        responses = [SimpleNamespace(returncode=0, stdout="app", stderr=""),
                     SimpleNamespace(returncode=0, stdout="app1", stderr=""),
                     SimpleNamespace(returncode=0, stdout=json.dumps([foreign]), stderr="")]
        with patch.object(LOGS, "run", side_effect=responses):
            with self.assertRaisesRegex(RuntimeError, "ownership"):
                LOGS.containers(["docker-compose"], "/repo/compose.yml")

    def test_readiness_waits_only_while_health_is_starting(self):
        args = self.args(wait_seconds=60)
        output = io.StringIO()
        with patch.object(LOGS, "containers", return_value=(["app"], [record()])) as initial, \
                patch.object(LOGS.time, "sleep") as sleep, contextlib.redirect_stdout(output):
            self.assertEqual(LOGS.readiness(args, ["docker-compose"]), 1)
            initial.assert_called_once()
            sleep.assert_not_called()
        self.assertIn("call docker_up", output.getvalue())
        with patch.object(LOGS, "containers", return_value=(["app"], [record(state="running", health="starting")])), \
                patch.object(LOGS, "inspect_containers", return_value=[record(state="running", health="healthy")]) as inspect, \
                patch.object(LOGS.time, "sleep") as sleep:
            self.assertEqual(LOGS.readiness(args, ["docker-compose"]), 0)
            sleep.assert_called_once_with(1)
            inspect.assert_called_once()

    def test_missing_empty_and_unknown_services(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(LOGS.show_logs(self.args(), ["app"], []), 0)
        self.assertIn("No container exists", output.getvalue())
        args = self.args()
        args.service = ["unknown"]
        with self.assertRaisesRegex(RuntimeError, "Unknown Compose"):
            LOGS.show_logs(args, ["app"], [])
        with patch.object(LOGS, "run", return_value=SimpleNamespace(
                returncode=0, stdout="", stderr="")), contextlib.redirect_stdout(output):
            self.assertEqual(LOGS.show_logs(self.args(), ["app"], [record()]), 0)
        self.assertIn("<empty>", output.getvalue())

    def test_engine_error_and_truncation(self):
        with patch.object(LOGS, "run", return_value=SimpleNamespace(
                returncode=1, stdout="", stderr="engine inaccessible")):
            with self.assertRaisesRegex(RuntimeError, "engine inaccessible"):
                LOGS.containers(["docker-compose"], "/repo/compose.yml")
        output = io.StringIO()
        with patch.object(LOGS, "run", return_value=SimpleNamespace(
                returncode=0, stdout="x" * 300000, stderr="")), contextlib.redirect_stdout(output):
            LOGS.show_logs(self.args(), ["app"], [record()])
        self.assertIn("[truncated]", output.getvalue())
        self.assertLess(len(output.getvalue()), 263000)

    def test_json_preserves_partial_results_on_read_error(self):
        args = self.args()
        args.json = True
        output = io.StringIO()
        responses = [SimpleNamespace(returncode=1, stdout="read failed", stderr=None),
                     SimpleNamespace(returncode=0, stdout="", stderr="")]
        with patch.object(LOGS, "run", side_effect=responses), contextlib.redirect_stdout(output):
            self.assertEqual(LOGS.show_logs(args, ["app", "db"],
                                           [record(), record(replica="2")]), 1)
        snapshot = json.loads(output.getvalue())
        self.assertEqual(snapshot["missingServices"], ["db"])
        failed, empty = snapshot["containers"]
        self.assertEqual(failed["readStatus"], "error")
        self.assertEqual(failed["error"], "read failed")
        self.assertEqual(empty["readStatus"], "empty")
        self.assertEqual(empty["logs"], [])

    def test_time_window_and_literal_filter_across_service_counts(self):
        for count in (1, 3, 5):
            args = self.args()
            args.since = "5m"
            args.contains = "failure[1]"
            services = [f"app{i}" for i in range(count)]
            records = [record(service) for service in services]
            for item in records:
                item["State"]["StartedAt"] = "2026-11-22T17:33:00Z"
            response = SimpleNamespace(returncode=0, stdout="failure1\nfailure[1]\n", stderr="")
            with patch.object(LOGS, "run", return_value=response) as run:
                snapshot = LOGS.capture_logs(args, services, records)
                run.assert_any_call(["docker", "logs", "--tail", "100", "--since", "5m", records[0]["Id"]], merge_streams=True)
                self.assertEqual(len(snapshot["containers"]), count)
                for entry in snapshot["containers"]:
                    self.assertEqual(entry["logs"], ["failure[1]"])
                    self.assertEqual(entry["startedAt"], "2026-11-22T17:33:00Z")
                args.contains = "absent"
                self.assertEqual(LOGS.capture_logs(args, services, records)["containers"][0]["readStatus"],
                                 "no_matches")

    def test_suggestion_reaches_interactive_frontend_details(self):
        import tempfile

        with tempfile.TemporaryDirectory() as directory:
            detail = Path(directory) / "details"
            detail.write_text("original diagnostic\n")
            with patch.dict("os.environ", {"MAKEVN_BACKEND_DETAIL_OUT": str(detail)}):
                with contextlib.redirect_stdout(io.StringIO()):
                    LOGS.suggest(self.args(), [record()])
            self.assertEqual(detail.read_text().splitlines(), [
                "original diagnostic",
                "Suggested log query: makevn --repo /repo docker-logs --compose boot "
                "--service app --compose-file /repo/compose.yml",
            ])

    def test_combined_logs_keep_emission_order(self):
        result = LOGS.run([sys.executable, "-u", "-c",
                           "import os; os.write(1, b'first\\n'); os.write(2, b'second\\n'); os.write(1, b'third\\n')"],
                          merge_streams=True)
        self.assertEqual(result.stdout.splitlines(), ["first", "second", "third"])

    def test_no_containers_does_not_suggest_logs(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            LOGS.suggest(self.args(), [])
        self.assertIn("No containers exist", output.getvalue())
        self.assertNotIn("docker-logs", output.getvalue())


class DockerLogsEntryPointTest(unittest.TestCase):
    def test_cli_and_mcp_after_partial_startup_and_required(self):
        import os
        import subprocess
        import tempfile
        from mcp_client import request

        binary = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / "rust/dispatcher/target/debug/makevn"
        mcp = Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else ROOT / "rust/dispatcher/target/debug/makevn-mcp"
        if not binary.exists():
            self.skipTest("Build the Rust dispatcher before entry-point tests")
        with tempfile.TemporaryDirectory(prefix="makevn-logs-") as directory:
            repo = Path(directory)
            (repo / "pom.xml").write_text("<project><modelVersion>4.0.0</modelVersion><groupId>x</groupId><artifactId>a</artifactId><version>1</version></project>")
            (repo / ".makevn").mkdir()
            compose = repo / "docker-compose.yml"
            compose.write_text("services:\n  app:\n    image: fixture\n")
            fake = repo / "fake-bin"
            fake.mkdir()
            script = """import json, os, sys
from pathlib import Path
args = sys.argv[1:]
repo = Path(os.environ["LOG_TEST_REPO"])
if Path(sys.argv[0]).name == "docker-compose":
    if "config" in args:
        print("app")
    elif "up" in args:
        print("original startup failure", file=sys.stderr)
        sys.exit(23)
    elif "ps" in args:
        print("app1")
elif args[0] == "inspect":
    if "-f" in args:
        template = args[args.index("-f") + 1]
        print("exited" if "Status" in template and "Health" not in template else "none" if "Health" in template else "1")
    else:
        print(json.dumps([{"Id":"app1", "Name":"/app-1",
            "Config":{"Labels":{"com.docker.compose.project.working_dir":os.environ.get("LOG_TEST_FOREIGN", str(repo)),
            "com.docker.compose.project.config_files":str(repo / "docker-compose.yml"),
            "com.docker.compose.service":"app"}},
            "State":{"Status":"exited"}}]))
elif args[0] == "logs":
    print("specific application failure")
"""
            for name in ("docker", "docker-compose"):
                path = fake / name
                path.write_text("#!" + sys.executable + "\n" + script)
                path.chmod(0o755)
            env = dict(os.environ, PATH=str(fake) + os.pathsep + os.environ["PATH"],
                       MAKEVN_INSTALL_ROOT=str(ROOT), LOG_TEST_REPO=str(repo))
            with patch.dict(os.environ, env, clear=True):
                for tool, extra in (("docker_up", {}), ("karate_docker_up", {}),
                                    ("docker_ps_required", {"compose": "boot"}),
                                    ("docker_ps_required", {"compose": "karate"})):
                    arguments = dict(repo=str(repo), **{"compose-file": str(compose)}, **extra)
                    result = request(str(mcp), {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                        "params": {"name": tool, "arguments": arguments}})["result"]["structuredContent"]
                    self.assertNotEqual(result["exitCode"], 0, result)
                    suggestion = result["nextSuggestion"]
                    query = json.JSONDecoder().raw_decode(suggestion.split("arguments ", 1)[1])[0]
                    if tool == "docker_ps_required":
                        startup = "docker_up" if extra["compose"] == "boot" else "karate_docker_up"
                        self.assertIn("call " + startup, suggestion)
                        self.assertNotIn("compose", query)
                        self.assertEqual(result["untrustedData"]["dockerDiagnosis"]["containers"][0]["state"], "exited")
                        continue
                    self.assertTrue(suggestion.startswith("Use docker_logs with arguments "), result)
                    self.assertEqual(query["services"], ["app"])
                    query.update(since="5m", contains="application")
                    logs = request(str(mcp), {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                        "params": {"name": "docker_logs", "arguments": query}})["result"]["structuredContent"]
                    self.assertEqual(logs["exitCode"], 0, logs)
                    snapshot = logs["untrustedData"]["dockerLogs"]
                    self.assertIn("specific application failure", logs["untrustedData"]["output"])
                    self.assertIn("readStatus=", logs["untrustedData"]["output"])
                    self.assertEqual(snapshot["containers"][0]["logs"], ["specific application failure"])
                    self.assertEqual(snapshot["containers"][0]["state"], "exited")
                    self.assertEqual(snapshot["containers"][0]["readStatus"], "ok")
                with patch.dict(os.environ, {"LOG_TEST_FOREIGN": "/other-worktree"}):
                    for tool in ("docker_ps_required", "docker_up", "docker_logs"):
                        result = request(str(mcp), {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                            "params": {"name": tool, "arguments": {
                                "repo": str(repo), "compose-file": str(compose)}}})["result"]["structuredContent"]
                        self.assertEqual(result["exitCode"], 1, result)
                        self.assertEqual(result["untrustedData"]["dockerDiagnosis"]["code"],
                                         "ownership_unverified", result)
                        self.assertIn("Compose ownership is unverified", result["nextSuggestion"])
                        self.assertNotIn("original startup failure", result["untrustedData"]["output"])
                cli = subprocess.run([str(binary), "--repo", str(repo), "docker-logs",
                                      "--compose-file", str(compose), "--service", "app", "--tail", "50", "--since", "5m",
                                      "--contains", "application", "--json"],
                                     env=env, capture_output=True, text=True)
                self.assertEqual(cli.returncode, 0, cli.stdout + cli.stderr)
                self.assertEqual(json.loads(cli.stdout)["containers"], snapshot["containers"])


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]])
