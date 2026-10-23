#!/usr/bin/env python3
"""Render concise human-readable doctor diagnostics; JSON retains full evidence."""

import json
import sys


def summarize(processes, mounts):
    status = processes.get("status", "unavailable")
    if status == "clear":
        yield "Test JVMs: no competing test JVMs detected"
    elif status == "unavailable":
        yield "Test JVMs: inspection unavailable"
    else:
        for process in processes.get("processes", []):
            yield f"Test JVM warning: PID {process['pid']} in {process['checkout']}; possible shared-service conflict"
        unknown = processes.get("unattributed_test_jvms", 0)
        if unknown:
            yield f"Test JVMs: {unknown} could not be attributed to a repository"

    checks = mounts.get("checks", [])
    if mounts.get("status") == "unavailable":
        yield "Bind mounts: verification unavailable"
    elif not checks:
        yield "Bind mounts: none detected"
    else:
        pending = sum(check.get("status") != "visible" for check in checks)
        yield f"Bind mounts: {len(checks)} detected, {pending} pending visibility verification"
        for check in checks:
            if check.get("status") in ("warning", "error", "empty_source"):
                yield f"Bind mount {check['status']}: {check['service']} {check['source']} -> {check['target']}: {check.get('reason', 'inspection required')}"


if __name__ == "__main__":
    print("\n".join(summarize(json.loads(sys.argv[1]), json.loads(sys.argv[2]))))
