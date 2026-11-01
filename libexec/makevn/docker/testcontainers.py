"""Check the Testcontainers engine and pass a local Docker context to Java."""

import os
from pathlib import Path, PurePosixPath
import subprocess
import sys


def docker_output(arguments, environment):
    result = subprocess.run(
        ["docker", *arguments], env=environment, capture_output=True,
        text=True, timeout=15, check=False,
    )
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "Docker command failed")
    return result.stdout.strip()


def test_environment(environment):
    environment = environment.copy()
    if not environment.get("DOCKER_HOST"):
        context = environment.get("DOCKER_CONTEXT") or docker_output(
            ["context", "show"], environment,
        )
        host = docker_output(
            ["context", "inspect", context, "--format", "{{.Endpoints.docker.Host}}"],
            environment,
        )
        if not host.startswith("unix://"):
            raise RuntimeError(
                "The selected Docker context is not a local Unix endpoint. "
                "Configure DOCKER_HOST and any required TLS settings for Testcontainers."
            )
        environment["DOCKER_HOST"] = host
    if "TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE" not in environment and colima_socket(environment):
        environment["TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE"] = "/var/run/docker.sock"
    # Docker CLI context precedence must not probe a different engine from Java.
    environment.pop("DOCKER_CONTEXT", None)
    version = docker_output(["info", "--format", "{{.ServerVersion}}"], environment)
    if not version:
        raise RuntimeError("Docker returned no server version")
    return environment


def colima_socket(environment):
    host = environment.get("DOCKER_HOST", "")
    if not host.startswith("unix://"):
        return False
    home = PurePosixPath(environment.get("HOME", str(Path.home())))
    try:
        relative = PurePosixPath(host[len("unix://"):]).relative_to(home / ".colima")
    except ValueError:
        return False
    return len(relative.parts) == 2 and relative.parts[0] != ".." and relative.parts[1] == "docker.sock"


def main():
    try:
        environment = test_environment(os.environ)
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"[ERROR] Testcontainers Docker prerequisite failed: {error}", file=sys.stderr)
        print(
            "[ERROR] Tests were not started. Check the engine and Testcontainers endpoint "
            "configuration. docker-up starts Compose services, not the Docker engine.",
            file=sys.stderr,
        )
        return 1
    print("Testcontainers Docker prerequisite passed; containers are managed by the tests.", flush=True)
    os.execvpe(sys.argv[1], sys.argv[1:], environment)


if __name__ == "__main__":
    sys.exit(main())
