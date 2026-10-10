"""Read-only bind-mount diagnostics; never provision containers or alter data."""
import json
from itertools import islice
from pathlib import Path
import shutil
import subprocess
import sys


def query(argv, cwd):
    try:
        return subprocess.run(argv, cwd=cwd, capture_output=True, text=True, timeout=15)
    except (OSError, subprocess.TimeoutExpired):
        return None


def compose_command(repo, compose, override):
    command = ["docker", "compose"] if shutil.which("docker") else ["docker-compose"]
    command += ["-f", compose]
    if override and Path(override).is_file():
        command += ["-f", override]
    return command


def source_samples(source):
    path = Path(source)
    if not path.exists():
        return None
    if path.is_file():
        return [""]
    # Bounded immediate samples, including hidden files; no content or secrets read.
    try:
        return [entry.name for entry in islice(path.iterdir(), 8) if entry.exists()]
    except OSError:
        return None


def diagnostics(mode, repo, compose, override=""):
    if not compose or not Path(compose).is_file():
        return {"status": "unavailable", "checks": []}
    command = compose_command(repo, compose, override)
    result = query(command + ["config", "--format", "json"], repo)
    if result is None or result.returncode:
        return {"status": "unavailable", "checks": [], "note": "Resolved compose JSON unavailable; bind mounts were not verified."}
    try:
        services = json.loads(result.stdout)["services"]
    except (ValueError, KeyError, TypeError):
        return {"status": "unavailable", "checks": []}
    checks = []
    for service, config in services.items():
        for volume in config.get("volumes", []):
            if not isinstance(volume, dict) or volume.get("type") != "bind":
                continue
            source, target = volume.get("source"), volume.get("target")
            if not source or not target:
                continue
            samples = source_samples(source)
            check = {"service": service, "source": source, "target": target, "status": "unverified"}
            if samples is None:
                check.update(status="warning", reason="Host source is missing or unreadable; remote daemon paths may differ.")
            elif not samples:
                check.update(status="warning", reason="Host source directory is empty; initialization data may be missing.")
            elif mode == "required":
                verify_visible(command, repo, service, target, samples, check)
            checks.append(check)
    failed = any(check["status"] == "error" for check in checks)
    return {"status": "error" if failed else "checked", "checks": checks}


def verify_visible(command, repo, service, target, samples, check):
    ids = query(command + ["ps", "-q", service], repo)
    if ids is None or ids.returncode or not ids.stdout.strip():
        return
    for cid in ids.stdout.split():
        for sample in samples:
            destination = target.rstrip("/") + ("/" + sample if sample else "")
            visible = query(["docker", "exec", cid, "test", "-e", destination], repo)
            if visible is None or visible.returncode not in (0, 1) or visible.stderr.strip():
                check.update(status="unverified", reason="Container visibility probe unavailable (test executable/permissions/runtime).")
                return
            if visible.returncode == 1:
                check.update(status="error", reason="bind_mount_visibility_mismatch: host entry is absent or inaccessible inside the container; mount sharing or permissions require investigation.")
                return
    check["status"] = "visible"


def main():
    mode, repo, compose = sys.argv[1:4]
    result = diagnostics(mode, repo, compose, sys.argv[4] if len(sys.argv) > 4 else "")
    if mode == "doctor":
        print(json.dumps(result))
    else:
        if result["status"] == "unavailable":
            print("Bind mount visibility unverified: resolved compose JSON unavailable.")
        for check in result["checks"]:
            if check["status"] in ("error", "warning", "unverified"):
                print(f"Bind mount {check['status']}: {check['service']} {check['source']} -> {check['target']}: {check.get('reason', 'visibility not verified')}")
        if result["status"] == "error":
            print("Do not repeat tests or change credentials. Confirm mount sharing/checkout accessibility with the user, then recreate affected services and verify initialization. Do not reconfigure the VM or delete volumes without authorization.")
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
