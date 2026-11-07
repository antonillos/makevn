"""Resolve settings environment references without passing secrets in arguments."""
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import sys
import xml.etree.ElementTree as ET


SERVICE = os.environ.get("MAKEVN_MAVEN_SECRET_SERVICE") or "makevn.maven.environment"
REFERENCE = re.compile(r"\$\{env\.([A-Za-z_][A-Za-z0-9_]*)\}")


class SecretUnavailable(Exception):
    """A safe diagnostic containing names, never secret values."""


def settings_paths(arguments, cwd, environment):
    directory = Path(environment.get("MAVEN_PROJECTBASEDIR", cwd))
    project = next((p for p in (directory, *directory.parents) if (p / ".mvn").is_dir()), directory)
    config = project / ".mvn/maven.config"
    defaults = shlex.split(config.read_text(), comments=True) if config.is_file() else []
    args = defaults + shlex.split(environment.get("MAVEN_ARGS", "")) + list(arguments)
    selected = {}
    aliases = {"-s": "user", "--settings": "user", "-gs": "global", "--global-settings": "global"}
    iterator = iter(args)
    for argument in iterator:
        if argument == "--":
            break
        option, separator, value = argument.partition("=")
        if option in aliases:
            selected[aliases[option]] = value if separator else next(iterator, "")
        elif argument.startswith("-gs") and len(argument) > 3:
            selected["global"] = argument[3:]
        elif argument.startswith("-s") and len(argument) > 2:
            selected["user"] = argument[2:]
    paths = [Path(selected.get("user", str(Path.home() / ".m2/settings.xml")))]
    if "global" in selected:
        paths.append(Path(selected["global"]))
    elif environment.get("MAVEN_HOME"):
        paths.append(Path(environment["MAVEN_HOME"]) / "conf/settings.xml")
    else:
        executable = shutil.which(arguments[0]) if arguments else None
        if executable and Path(executable).name == "mvn":
            paths.append(Path(executable).resolve().parent.parent / "conf/settings.xml")
    return [path if path.is_absolute() else Path(cwd) / path for path in paths]


def references(paths):
    names = set()
    for path in paths:
        if path.is_file():
            root = ET.parse(path).getroot()
            for element in root.iter():
                names.update(REFERENCE.findall(element.text or ""))
                for value in element.attrib.values():
                    names.update(REFERENCE.findall(value))
    return sorted(names)


def lookup(name):
    if sys.platform == "darwin":
        command = ["/usr/bin/security", "find-generic-password", "-s", SERVICE, "-a", name, "-w"]
    elif sys.platform.startswith("linux") and shutil.which("secret-tool"):
        command = ["secret-tool", "lookup", "service", SERVICE, "account", name]
    else:
        raise SecretUnavailable(f"Maven settings variable {name} is missing; native secret store unavailable. "
                         "See https://github.com/antonillos/makevn/blob/develop/skills/makevn/references/maven-secrets.md; never send secrets in chat or project config.")
    try:
        result = subprocess.run(command, capture_output=True, timeout=15, check=False)
    except (OSError, subprocess.TimeoutExpired):
        raise SecretUnavailable(f"Cannot access native secret store for Maven settings variable {name}. "
                         "Unlock/configure the store; see https://github.com/antonillos/makevn/blob/develop/skills/makevn/references/maven-secrets.md.") from None
    if result.returncode or not result.stdout:
        raise SecretUnavailable(f"Native secret unavailable for Maven settings variable {name}. "
                         f"Configure service {SERVICE}, account {name}; see https://github.com/antonillos/makevn/blob/develop/skills/makevn/references/maven-secrets.md.")
    value = result.stdout.decode().removesuffix("\n")
    if not value or "\0" in value:
        raise SecretUnavailable(f"Native secret for Maven settings variable {name} is empty or invalid. "
                                "Update it locally; see https://github.com/antonillos/makevn/blob/develop/skills/makevn/references/maven-secrets.md.")
    return value


def run(arguments):
    environment = os.environ.copy()
    # Existing env assignments belong to the child and take precedence over the store.
    offset = 1 if arguments and arguments[0] == "env" else 0
    while offset and offset < len(arguments) and "=" in arguments[offset]:
        name, value = arguments[offset].split("=", 1)
        environment[name] = value
        offset += 1
    command = arguments[offset:]
    if not command or Path(command[0]).name not in {"mvn", "mvnw"}:
        os.execvpe(arguments[0], arguments, environment)
    names = references(settings_paths(command, Path.cwd(), environment))
    for name in names:
        if not environment.get(name):
            environment[name] = lookup(name)
    values = sorted({environment[name] for name in names if environment.get(name)}, key=len, reverse=True)
    if not values:
        os.execvpe(command[0], command, environment)
    redactions = sorted({part.encode() for value in values for part in value.splitlines() if part},
                        key=len, reverse=True)
    with subprocess.Popen(command, env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT) as process:
        def forward(number, frame):
            try:
                process.send_signal(number)
            except ProcessLookupError:
                pass
        previous = {number: signal.signal(number, forward) for number in (signal.SIGINT, signal.SIGTERM)}
        try:
            for line in process.stdout:
                for value in redactions:
                    line = line.replace(value, b"[REDACTED]")
                sys.stdout.buffer.write(line)
                sys.stdout.buffer.flush()
            status = process.wait()
        finally:
            for number, handler in previous.items():
                signal.signal(number, handler)
    return status if status >= 0 else 128 - status


if __name__ == "__main__":
    try:
        sys.exit(run(sys.argv[1:]))
    except SecretUnavailable as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
    except (OSError, ValueError, ET.ParseError):
        # Parser and operating-system exceptions may include sensitive XML or values.
        print("Maven settings secret resolution failed. Check settings and native-store setup; "
              "see https://github.com/antonillos/makevn/blob/develop/skills/makevn/references/maven-secrets.md.", file=sys.stderr)
        sys.exit(1)
