"""Read bounded logs and diagnose containers owned by the selected Compose stack."""

import argparse
import json
import os
import shlex
import subprocess
import sys


def run(command, *, merge_streams=False):
    stderr = subprocess.STDOUT if merge_streams else subprocess.PIPE
    return subprocess.run(command, stdout=subprocess.PIPE, stderr=stderr,
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
    cli_suggestion = "Suggested log query: " + shlex.join(command)
    print(cli_suggestion)
    if detail := os.environ.get("MAKEVN_BACKEND_DETAIL_OUT"):
        with open(detail, "a", encoding="utf-8") as stream:
            print(cli_suggestion, file=stream)
    suggestion = "Use docker_logs with arguments " + json.dumps(arguments)
    print("MCP docker_logs arguments: " + json.dumps(arguments))
    metadata = os.environ.get("MAKEVN_DOCKER_LOG_SUGGESTION_OUT")
    if metadata:
        with open(metadata, "w", encoding="utf-8") as stream:
            stream.write(suggestion)


def started_at(state):
    value = state.get("StartedAt")
    return value if value and not value.startswith("0001-01-01") else None


def filter_lines(output, contains, entry):
    if contains is not None:
        output = "".join(line for line in output.splitlines(keepends=True) if contains in line)
    entry["readStatus"] = "ok" if output else "no_matches"
    return output


def read_container_logs(record, args, remaining):
    state = record["State"]
    entry = dict(service=service_of(record), container=record["Name"].lstrip("/"),
                 state=state.get("Status"), health=(state.get("Health") or {}).get("Status"),
                 exitCode=state.get("ExitCode"), startedAt=started_at(state), logs=[], readStatus="empty",
                 error=None, truncated=False)
    try:
        command = ["docker", "logs", "--tail", str(args.tail)]
        if since := getattr(args, "since", None):
            command.extend(["--since", since])
        result = run(command + [record["Id"]], merge_streams=True)
        output = result.stdout
        if result.returncode:
            entry["readStatus"] = "error"
    except (OSError, subprocess.TimeoutExpired) as error:
        output = str(error)
        entry["readStatus"] = "error"
    if output and entry["readStatus"] != "error":
        output = filter_lines(output, getattr(args, "contains", None), entry)
    encoded = output.encode("utf-8")
    bounded = encoded[:remaining].decode("utf-8", errors="ignore")
    entry["truncated"] = len(encoded) > remaining
    if entry["readStatus"] == "error":
        entry["error"] = bounded or "Container logs unavailable."
    else:
        entry["logs"] = bounded.splitlines()
    return entry, max(0, remaining - len(encoded))


def capture_logs(args, services, records):
    unknown = set(args.service) - set(services)
    if unknown:
        raise RuntimeError("Unknown Compose services: " + ", ".join(sorted(unknown)))
    selected = list(dict.fromkeys(args.service or services))
    snapshot = dict(compose=args.compose, containers=[], missingServices=[], truncated=False)
    snapshot["since"] = getattr(args, "since", None)
    snapshot["contains"] = getattr(args, "contains", None)
    remaining = 262144
    for service in selected:
        matches = [record for record in records if service_of(record) == service]
        if not matches:
            snapshot["missingServices"].append(service)
        for record in matches:
            entry, remaining = read_container_logs(record, args, remaining)
            snapshot["containers"].append(entry)
            snapshot["truncated"] |= entry["truncated"]
    return snapshot


def print_snapshot(snapshot):
    for service in snapshot["missingServices"]:
        print(f"[{service}] No container exists.")
    for entry in snapshot["containers"]:
        print(f"[{entry['service']}/{entry['container']}]")
        if entry["error"]:
            print(f"Container logs unavailable: {entry['error']}")
        elif entry["logs"]:
            print("\n".join(entry["logs"]))
        elif entry["readStatus"] == "empty":
            print("<empty>")
        elif entry["readStatus"] == "no_matches":
            print("<no matching lines>")
    if snapshot["truncated"]:
        print("[truncated] Log response reached the 262144-byte content limit.")


def show_logs(args, services, records):
    snapshot = capture_logs(args, services, records)
    if getattr(args, "json", False):
        print(json.dumps(snapshot))
    else:
        print_snapshot(snapshot)
    return int(any(entry["readStatus"] == "error" for entry in snapshot["containers"]))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["logs", "suggest"])
    parser.add_argument("--repo", required=True)
    parser.add_argument("--compose", choices=["boot", "karate"], default="boot")
    parser.add_argument("--file", required=True)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--service", action="append", default=[])
    parser.add_argument("--since")
    parser.add_argument("--contains")
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
