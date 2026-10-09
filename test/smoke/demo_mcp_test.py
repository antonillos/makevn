"""Demo transport failures are tested separately from the client."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import unittest
import tempfile

spec = importlib.util.spec_from_file_location("demo", Path(__file__).resolve().parents[2] / "docs/demo/mcp_demo.py")
demo = importlib.util.module_from_spec(spec)
spec.loader.exec_module(demo)


class DemoMcpTest(unittest.TestCase):
    def run_response(self, response, behavior="normal", timeout=2):
        with tempfile.TemporaryDirectory() as tmp:
            server = Path(tmp) / "server"
            transcript = Path(tmp) / "requests.jsonl"
            server.write_text("#!/usr/bin/env python3\n" +
                "import json, sys, time\n" +
                "request=json.loads(sys.stdin.readline())\n" +
                "print(json.dumps({'id': 1, 'result': {}}), flush=True)\n" +
                "notification=json.loads(sys.stdin.readline())\n" +
                "request=json.loads(sys.stdin.readline())\n" +
                "open(" + repr(str(transcript)) + ", 'w').write(json.dumps([notification,request]))\n" +
                ("time.sleep(3)\n" if behavior == "timeout" else
                 "sys.exit(2)\n" if behavior == "exit" else
                 "print(" + repr(json.dumps(response)) + ", flush=True)\n"))
            server.chmod(0o700)
            with contextlib.redirect_stdout(io.StringIO()):
                result = demo.call("doctor", {"repo": "/tmp/demo"}, timeout=timeout, server=str(server))
            messages = json.loads(transcript.read_text())
            self.assertEqual(messages[0]["method"], "notifications/initialized")
            self.assertNotIn("trace", messages[1]["params"]["arguments"])
            return result

    def test_success(self):
        envelope = {"status": "success", "exitCode": 0}
        self.assertEqual(self.run_response({"id": 2, "result": {"structuredContent": envelope}}), envelope)

    def test_tool_failure(self):
        for result in [{"isError": True, "structuredContent": {"status": "success", "exitCode": 0}},
                       {"structuredContent": {"status": "error", "exitCode": 0}},
                       {"structuredContent": {"status": "success", "exitCode": 7}}]:
            with self.subTest(result=result), self.assertRaises(RuntimeError):
                self.run_response({"id": 2, "result": result})

    def test_protocol_error(self):
        with self.assertRaises(RuntimeError):
            self.run_response({"id": 2, "error": {"code": -32602, "message": "bad tool"}})

    def test_missing_response(self):
        with self.assertRaises(RuntimeError):
            self.run_response({"id": 3, "result": {}})

    def test_timeout(self):
        with self.assertRaises(subprocess.TimeoutExpired):
            self.run_response({}, behavior="timeout", timeout=0.1)

    def test_server_exit(self):
        with self.assertRaises(RuntimeError):
            self.run_response({}, behavior="exit")


class SessionFailureTest(unittest.TestCase):
    def test_failed_command_exits_the_recording_shell(self):
        session = Path(__file__).resolve().parents[2] / "docs/demo/session.sh"
        proc = subprocess.run(["bash", "-c", 'source "$1"; set +e; false; makevn_demo_prompt', "demo", str(session)],
                              capture_output=True, text=True)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("recording rejected", proc.stderr)


class AgentEventTest(unittest.TestCase):
    def test_completed_tool_detection(self):
        spec = importlib.util.spec_from_file_location("agent_demo", Path(__file__).resolve().parents[2] / "docs/demo/agent_demo.py")
        agent = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(agent)
        self.assertEqual(agent.completed_tools({"item": {"type": "mcp_tool_call", "server": "makevn", "tool": "doctor", "status": "completed"}}), {"doctor"})
        self.assertEqual(agent.completed_tools({"part": {"tool": "makevn_composite_run", "state": {"status": "completed"}}}), {"composite_run"})
        self.assertEqual(agent.completed_tools({"tool": "makevn_doctor", "state": {"status": "running"}}), set())
        self.assertEqual(agent.completed_tools({"type": "mcp_tool_call", "server": "makevn", "tool": "doctor", "status": "completed", "result": {"isError": True}}), set())
        self.assertEqual(agent.completed_tools({"tool": "makevn_composite_run", "state": {"status": "completed", "output": '{"status":"error","exitCode":1}'}}), set())


if __name__ == "__main__":
    unittest.main()
