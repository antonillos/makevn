"""Read bounded logs and diagnose containers owned by the selected Compose stack."""

import argparse
import json
import os
import shlex
import subprocess
import sys


def run(command):
    return subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          text=True, errors="replace", timeout=30)


def containers(compose, compose_file):
    configured = run(compose + ["config", "--services"])
    if configured.returncode:
        raise RuntimeError(configured.stderr.strip())
    services = configured.stdout.split()
    selected = run(compose + ["ps", "-aq"])
    if selected.returncode:
        raise RuntimeError(selected.stderr.strip())
    ids = selected.stdout.split()
    if not ids:
        return services, []
    inspected = run(["docker", "inspect"] + ids)
    if inspected.returncode:
        raise RuntimeError(inspected.stderr.strip())
    records = json.loads(inspected.stdout)
    for record in records:
        labels = record.get("Config", {}).get("Labels") or {}
        directory = labels.get("com.docker.compose.project.working_dir", "")
        files = labels.get("com.docker.compose.project.config_files", "").split(",")
        if (not directory or os.path.realpath(directory) != os.path.dirname(os.path.realpath(compose_file))
                or os.path.realpath(compose_file) not in
                [os.path.realpath(path) for path in files if path]
                or labels.get("com.docker.compose.service") not in services):
            raise RuntimeError("Compose container ownership could not be verified for this worktree.")
    return services, records


def service_of(record):
    return record["Config"]["Labels"]["com.docker.compose.service"]


def suggest(args, records):
    affected = sorted({service_of(record) for record in records
                       if record["State"].get("Status") != "running"
                       or record["State"].get("Health", {}).get("Status", "none")
                       not in ("none", "healthy")})
    if not records:
        print("No containers exist for the selected Compose stack; inspect startup diagnostics.")
        return
    command = ["makevn", "--repo", args.repo, "docker-logs", "--compose", args.compose]
    for service in affected:
        command += ["--service", service]
    arguments = dict(repo=args.repo, compose=args.compose,
                     **({"services": affected} if affected else {}))
    arguments["compose-file"] = os.path.realpath(args.file)
    command += ["--compose-file", arguments["compose-file"]]
    print("Suggested log query: " + shlex.join(command))
    suggestion = "Use docker_logs with arguments " + json.dumps(arguments)
    print("MCP docker_logs arguments: " + json.dumps(arguments))
    metadata = os.environ.get("MAKEVN_DOCKER_LOG_SUGGESTION_OUT")
    if metadata:
        with open(metadata, "w", encoding="utf-8") as stream:
            stream.write(suggestion)


def show_logs(args, services, records):
    unknown = set(args.service) - set(services)
    if unknown:
        raise RuntimeError("Unknown Compose services: " + ", ".join(sorted(unknown)))
    selected = args.service or services
    remaining = 262144
    failed = False
    for service in selected:
        matches = [record for record in records if service_of(record) == service]
        if not matches:
            print(f"[{service}] No container exists.")
        for record in matches:
            name = record.get("Name", record["Id"]).lstrip("/")
            print(f"[{service}/{name}]")
            result = run(["docker", "logs", "--tail", str(args.tail), record["Id"]])
            output = result.stdout + result.stderr
            if result.returncode:
                failed = True
                print("Container logs unavailable.")
            encoded = output.encode("utf-8")
            if len(encoded) > remaining:
                print(encoded[:remaining].decode("utf-8", errors="ignore"))
                print("[truncated] Log response reached the 262144-byte content limit.")
                return 1 if failed else 0
            print(output or "<empty>", end="" if output.endswith("\n") else "\n")
            remaining -= len(encoded)
    return 1 if failed else 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["logs", "suggest"])
    parser.add_argument("--repo", required=True)
    parser.add_argument("--compose", choices=["boot", "karate"], default="boot")
    parser.add_argument("--file", required=True)
    parser.add_argument("--service", action="append", default=[])
    parser.add_argument("--tail", type=int, choices=range(1, 1001), default=100, metavar="1..1000")
    separator = sys.argv.index("--")
    args = parser.parse_args(sys.argv[1:separator])
    command = sys.argv[separator + 1:]
    os.chdir(args.repo)
    try:
        services, records = containers(command, args.file)
        if args.mode == "suggest":
            suggest(args, records)
            return 0
        return show_logs(args, services, records)
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"Docker log diagnosis unavailable: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
