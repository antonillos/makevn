"""Read bounded logs and diagnose containers owned by the selected Compose stack."""

import argparse
import json
import os
import shlex
import subprocess
import sys
import time


class OwnershipError(RuntimeError):
    pass


def run(command, *, merge_streams=False, deadline=None):
    stderr = subprocess.STDOUT if merge_streams else subprocess.PIPE
    timeout = 30 if deadline is None else min(30, deadline - time.monotonic())
    if timeout <= 0:
        raise subprocess.TimeoutExpired(command, 0)
    return subprocess.run(command, stdout=subprocess.PIPE, stderr=stderr,
                          text=True, errors="replace", timeout=timeout)


class DockerQueryError(RuntimeError):
    def __init__(self, code, detail):
        super().__init__(detail)
        self.code = code


def checked_run(command, deadline, code):
    result = run(command) if deadline is None else run(command, deadline=deadline)
    if result.returncode:
        raise DockerQueryError(code, result.stderr.strip() or "Docker query failed without diagnostics.")
    return result.stdout


def containers(compose, compose_file, deadline=None):
    services = checked_run(compose + ["config", "--services"], deadline, "compose_config_failed").split()
    if not services:
        raise DockerQueryError("compose_config_failed", "No services defined in the selected Compose stack.")
    return services, inspect_containers(compose, compose_file, services, deadline)


def inspect_containers(compose, compose_file, services, deadline):
    ids = checked_run(compose + ["ps", "-aq"], deadline, "container_listing_failed").split()
    if not ids:
        return []
    records = json.loads(checked_run(["docker", "inspect"] + ids, deadline, "inspection_failed"))
    if len(records) != len(ids) or any(
            not any(record["Id"].startswith(cid) for record in records) for cid in ids):
        raise DockerQueryError("inspection_failed", "Docker inspect did not return every selected container.")
    expected_file = os.path.realpath(compose_file)
    expected_directory = os.path.dirname(expected_file)
    for record in records:
        labels = record.get("Config", {}).get("Labels") or {}
        directory = labels.get("com.docker.compose.project.working_dir", "")
        files = labels.get("com.docker.compose.project.config_files", "").split(",")
        service = labels.get("com.docker.compose.service")
        if (not directory or os.path.realpath(directory) != expected_directory
                or expected_file not in [os.path.realpath(path) for path in files if path]
                or service not in services):
            raise OwnershipError(
                f"Compose container ownership could not be verified for this worktree. "
                f"Container: {record['Id'][:12]}; expected working_dir={expected_directory!r}, "
                f"config_files containing {expected_file!r} and a configured service; "
                f"observed working_dir={directory!r}, config_files={files!r}, service={service!r}."
            )
    return records


def publish_suggestion(suggestion, *, display=True):
    if display:
        print(suggestion)
    metadata = os.environ.get("MAKEVN_DOCKER_LOG_SUGGESTION_OUT")
    if metadata:
        with open(metadata, "w", encoding="utf-8") as stream:
            stream.write(suggestion)


def readiness(args, command):
    deadline = time.monotonic() + args.wait_seconds if args.wait_seconds else None
    services, records = containers(command, args.file, deadline)
    while True:
        missing = sorted(set(services) - {service_of(record) for record in records})
        failed = [record for record in records if replica_status(record) not in
                  {("running", "none"), ("running", "healthy")}]
        if not missing and not failed:
            return 0
        if (missing or not deadline or
                any(replica_status(record) != ("running", "starting") for record in failed)):
            break
        remaining = deadline - time.monotonic()
        if remaining <= 1:
            break
        time.sleep(1)
        try:
            records = inspect_containers(command, args.file, services, deadline)
        except subprocess.TimeoutExpired as error:
            if time.monotonic() < deadline:
                raise
            diagnosis("readiness_timeout", detail=str(error))
            publish_suggestion("The readiness probe exceeded its deadline. Check Docker engine "
                               "responsiveness before retrying the same Compose stack.")
            return 1

    print("Required Docker services are not running or healthy.")
    status = readiness_status(missing, failed)
    diagnosis(status, missingServices=missing, containers=[
        dict(service=service_of(record), state=replica_status(record)[0],
             health=replica_status(record)[1], exitCode=record["State"].get("ExitCode"))
        for record in failed
    ])
    if status == "startup_needed":
        tool = "docker_up" if args.compose == "boot" else "karate_docker_up"
        arguments = {"repo": args.repo, "compose-file": args.file}
        ready = dict(arguments, compose=args.compose, **{"wait-seconds": 30})
        publish_suggestion(f"With startup authorized, call {tool} with arguments "
                           f"{json.dumps(arguments)}. After success, call docker_ps_required "
                           f"with arguments {json.dumps(ready)}.")
    elif status == "inspection_failed":
        publish_suggestion("Resolve the unknown container state or health before starting services.")
    elif status == "services_starting":
        arguments = {"repo": args.repo, "compose": args.compose, "compose-file": args.file,
                     "wait-seconds": 30}
        if deadline:
            suggest(args, failed)
        else:
            publish_suggestion("Services are starting. Use docker_ps_required with arguments "
                               + json.dumps(arguments))
    else:
        suggest(args, failed)
    return 1


def readiness_status(missing, failed):
    statuses = [replica_status(record) for record in failed]
    if any("unknown" in status for status in statuses):
        return "inspection_failed"
    if all(state in {"created", "exited"} for state, _ in statuses):
        return "startup_needed"
    if not missing and all(status == ("running", "starting") for status in statuses):
        return "services_starting"
    return "services_failed"


def diagnosis(code, **details):
    print("Docker diagnosis: " + json.dumps(dict(code=code, **details)))


def replica_status(record):
    state = record["State"]
    return state.get("Status", "unknown"), state.get("Health", {}).get("Status", "none")





def service_of(record):
    return record["Config"]["Labels"]["com.docker.compose.service"]


def suggest(args, records):
    affected = sorted({service_of(record) for record in records
                       if record["State"].get("Status") != "running"
                       or record["State"].get("Health", {}).get("Status", "none")
                       not in ("none", "healthy")})
    if not records:
        publish_suggestion("No containers exist for the selected Compose stack; "
                           "inspect the original startup diagnostics in this result.")
        return
    if not affected:
        publish_suggestion("The inspected containers are running. Resolve the original Compose startup "
                           "error in this result before retrying.")
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
    publish_suggestion("Use docker_logs with arguments " + json.dumps(arguments), display=False)
    print("MCP docker_logs arguments: " + json.dumps(arguments))


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
    parser.add_argument("mode", choices=["logs", "suggest", "readiness", "ownership"])
    parser.add_argument("--wait-seconds", type=int, default=0)
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
        if args.mode == "readiness":
            return readiness(args, command)
        services, records = containers(command, args.file)
        if args.mode == "ownership":
            return 0
        if args.mode == "suggest":
            suggest(args, records)
            return 0
        return show_logs(args, services, records)
    except OwnershipError as error:
        diagnosis("ownership_unverified", detail=str(error))
        publish_suggestion("Compose ownership is unverified. Check the expected and observed Compose "
                           "labels in untrustedData.output. Resolve the worktree or Compose selection "
                           "before starting, stopping, resetting or reading container logs.")
        return 1
    except DockerQueryError as error:
        diagnosis(error.code, detail=str(error))
        publish_suggestion({
            "compose_config_failed": "Check the reported Compose configuration error for the selected file before retrying.",
            "container_listing_failed": "Check Docker engine access for the selected Compose project before starting services.",
            "inspection_failed": "Resolve the container inspection failure before starting services or retrying readiness.",
        }[error.code])
        return 1
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        diagnosis("probe_failed", detail=f"Docker {args.mode} query failed: {error}")
        publish_suggestion("Resolve the reported Docker engine, Compose or inspection error "
                           "before retrying. See untrustedData.output for the failed query.")
        return 1


if __name__ == "__main__":
    sys.exit(main())
