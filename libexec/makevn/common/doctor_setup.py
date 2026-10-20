"""Structured doctor questions and atomic persistence shared with CLI prompts."""

import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import sys
import tempfile


SETTINGS = {
    "boot_compose": "MAKEVN_COMPOSE_FILE",
    "e2e_compose": "MAKEVN_E2E_COMPOSE_FILE",
    "local_containers": "MAKEVN_LOCAL_CONTAINERS",
    "app_health_url": "MAKEVN_APP_HEALTH_URL",
    "karate_app_profiles": "MAKEVN_KARATE_APP_PROFILES",
}


def valid_health_url(value):
    return re.fullmatch(r"https?://[^\s]+", value) is not None


def valid_profiles(value):
    return re.fullmatch(r"[A-Za-z0-9_.-]+(?:,[A-Za-z0-9_.-]+)*", value) is not None


def write_config(path, updates, original=None):
    """Replace only answered settings; never evaluate or interpolate user input."""
    # Lock a stable sidecar: replacing config changes its inode.
    with path.with_name(".config.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        _replace_config(path, updates, original)


def _replace_config(path, updates, original):
    original = path.read_bytes() if original is None else original
    lines = original.decode().splitlines(keepends=True)
    pattern = re.compile(r"^(?:" + "|".join(map(re.escape, updates)) + r")=")
    content = "".join(line for line in lines if not pattern.match(line))
    if content and not content.endswith("\n"):
        content += "\n"
    content += "".join(f"{key}={shlex.quote(value)}\n" for key, value in updates.items())
    fd, name = tempfile.mkstemp(prefix=".config-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as output:
            output.write(content)
        os.chmod(name, path.stat().st_mode & 0o777)
        if path.read_bytes() != original:
            raise ValueError("Configuration changed; run doctor and ask the updated questions.")
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def setup_token(repo, questions, config):
    data = json.dumps([str(repo.resolve()), questions], sort_keys=True).encode()
    return hashlib.sha256(data + b"\0" + config).hexdigest()


def question(identifier, prompt, kind, options=None, suggested=None):
    return {"id": identifier, "prompt": prompt, "type": kind,
            "options": options or [], "suggestedValue": suggested}


def collect_questions(arguments):
    repo, boot, e2e, health, profiles, local_pending, health_pending, profiles_pending = arguments
    questions = []
    for identifier, label, candidates in [
        ("boot_compose", "boot tests", boot), ("e2e_compose", "Karate E2E", e2e)
    ]:
        if candidates:
            questions.append(question(identifier, f"Which Docker Compose file should {label} use?",
                                      "choice", candidates.splitlines()))
    if local_pending == "true":
        questions.append(question("local_containers", "Use LOCAL_CONTAINERS=TRUE by default for tests?",
                                  "boolean", [True, False]))
    if health_pending == "true":
        questions.append(question("app_health_url", "Confirm or edit the application HTTP health URL. "
                                  "A suggested URL is not verified.", "string", suggested=health))
    if profiles_pending == "true":
        questions.append(question("karate_app_profiles", "Which literal comma-separated Spring profiles "
                                  f"should the Karate application use? Detected candidates: {profiles}", "string"))
    path = Path(repo) / ".makevn/config"
    config = path.read_bytes() if path.is_file() else b""
    return {"questions": questions, "setupToken": setup_token(Path(repo), questions, config), "available": True}


def answer_updates(setup, answers):
    if not isinstance(answers, dict) or not answers:
        raise ValueError("answers must be a nonempty object keyed by question id.")
    questions = {item["id"]: item for item in setup["questions"]}
    updates = {}
    for identifier, value in answers.items():
        if identifier not in questions:
            raise ValueError(f"Question {identifier!r} is unknown or no longer pending; ask the updated questions.")
        item = questions[identifier]
        if item["type"] == "boolean":
            if type(value) is not bool:
                raise ValueError(f"{identifier} requires a boolean answer.")
            value = "TRUE" if value else ""
        else:
            if not isinstance(value, str) or "\0" in value or "\n" in value or "\r" in value:
                raise ValueError(f"{identifier} requires a single-line string answer.")
            if item["type"] == "choice" and value not in item["options"]:
                raise ValueError(f"{identifier} must select a currently available option.")
            if identifier == "app_health_url" and not valid_health_url(value):
                raise ValueError("Use an HTTP(S) health URL without whitespace.")
            if identifier == "karate_app_profiles" and not valid_profiles(value):
                raise ValueError("Use a comma-separated list of literal Spring profile names.")
        updates[SETTINGS[identifier]] = value
    return updates


def apply_answers(repo, request, snapshot):
    if snapshot["repository_analysis"]["repository_support_status"] != "supported":
        raise ValueError("No Maven project detected; configuration was not changed.")
    if snapshot["suggested_next_step"]["next"]:
        raise ValueError("Follow doctor's initialization recommendation before answering setup questions.")
    path = Path(repo) / ".makevn/config"
    original = path.read_bytes()
    setup = snapshot["interactive_setup"]
    token = setup_token(Path(repo), setup["questions"], original)
    if request.get("setupToken") != token or setup["setupToken"] != token:
        raise ValueError("Doctor configuration or questions changed; ask the updated questions before applying answers.")
    updates = answer_updates(setup, request.get("answers"))
    write_config(path, updates, original)


def main():
    command, *arguments = sys.argv[1:]
    if command == "questions":
        print(json.dumps(collect_questions(arguments)))
    elif command == "apply":
        repo, request = arguments
        apply_answers(repo, json.loads(request), json.load(sys.stdin))
    elif command == "validate":
        identifier, value = arguments
        validator = {"app_health_url": valid_health_url, "karate_app_profiles": valid_profiles}[identifier]
        sys.exit(0 if validator(value) else 1)
    elif command == "set":
        path, key, value = arguments
        if key not in SETTINGS.values():
            raise ValueError("Unknown doctor setting.")
        write_config(Path(path), {key: value})


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError) as error:
        print(f"Doctor configuration unchanged: {error}", file=sys.stderr)
        sys.exit(2)
