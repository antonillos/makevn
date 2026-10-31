"""Extract actionable Docker API compatibility errors from complete Maven logs."""

from pathlib import Path
import re
import sys


OLD_CLIENT = re.compile(
    r"client version (\d+(?:\.\d+)+) is too old\.\s*"
    r"Minimum supported API version is (\d+(?:\.\d+)+)",
    re.IGNORECASE,
)


def diagnose(logfile):
    try:
        match = OLD_CLIENT.search(Path(logfile).read_text(errors="replace"))
    except OSError:
        return ""
    if not match:
        return ""
    client, minimum = match.groups()
    return (
        f"[ERROR] Docker API incompatibility: the project client uses API {client}; "
        f"the reachable engine requires at least API {minimum}. "
        "Check the project's Testcontainers/Docker client dependencies and API configuration. "
        "Starting Compose services does not fix this incompatibility."
    )


if __name__ == "__main__":
    diagnostic = diagnose(sys.argv[1])
    if diagnostic:
        print(diagnostic)
