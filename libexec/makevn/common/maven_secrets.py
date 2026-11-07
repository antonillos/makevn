"""Resolve settings environment references without passing secrets in arguments."""
import os
import json
import ctypes
from pathlib import Path
import pwd
import re
import shlex
import shutil
import signal
import subprocess
import sys
import uuid
import xml.etree.ElementTree as ET


DEFAULT_SERVICE = "makevn.maven.environment"
SERVICE = os.environ.get("MAKEVN_MAVEN_SECRET_SERVICE") or DEFAULT_SERVICE
REFERENCE = re.compile(r"\$\{env\.([A-Za-z_][A-Za-z0-9_]*)\}")


class SecretUnavailable(Exception):
    """A safe diagnostic containing names, never secret values."""


def keychain_match_count(account, service):
    """Count matching Keychain attributes without requesting password data."""
    security = ctypes.CDLL('/System/Library/Frameworks/Security.framework/Security')
    core = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
    pointer = ctypes.c_void_p
    core.CFDictionaryCreateMutable.argtypes = [pointer, ctypes.c_long, pointer, pointer]
    core.CFDictionaryCreateMutable.restype = pointer
    core.CFDictionarySetValue.argtypes = [pointer, pointer, pointer]
    core.CFStringCreateWithCString.argtypes = [pointer, ctypes.c_char_p, ctypes.c_uint32]
    core.CFStringCreateWithCString.restype = pointer
    core.CFArrayGetCount.argtypes = [pointer]
    core.CFArrayGetCount.restype = ctypes.c_long
    core.CFRelease.argtypes = [pointer]
    security.SecItemCopyMatching.argtypes = [pointer, ctypes.POINTER(pointer)]
    security.SecItemCopyMatching.restype = ctypes.c_int32
    query = core.CFDictionaryCreateMutable(None, 0, None, None)
    account_value = core.CFStringCreateWithCString(None, account.encode(), 0x08000100)
    service_value = core.CFStringCreateWithCString(None, service.encode(), 0x08000100)
    result = pointer()
    if not query or not account_value or not service_value:
        raise SecretUnavailable("Cannot inspect Keychain entries safely; configure the inherited environment instead.")
    try:
        def symbol(library, name):
            return pointer.in_dll(library, name)

        for key, value in [
            ("kSecClass", symbol(security, "kSecClassGenericPassword")),
            ("kSecAttrAccount", account_value), ("kSecAttrService", service_value),
            ("kSecReturnAttributes", symbol(core, "kCFBooleanTrue")),
            ("kSecMatchLimit", symbol(security, "kSecMatchLimitAll")),
        ]:
            core.CFDictionarySetValue(query, symbol(security, key), value)
        status = security.SecItemCopyMatching(query, ctypes.byref(result))
        if status == -25300:
            return 0
        if status != 0 or not result.value:
            raise SecretUnavailable("Cannot inspect Keychain entries safely; unlock Keychain and retry.")
        return core.CFArrayGetCount(result)
    finally:
        if result.value:
            core.CFRelease(result)
        for value in (query, account_value, service_value):
            if value:
                core.CFRelease(value)


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


def lookup_user_account(name):
    """Resolve a native entry whose service is the variable and account is the OS user."""
    try:
        account = pwd.getpwuid(os.getuid()).pw_name
    except KeyError:
        return None
    if sys.platform == "darwin":
        try:
            count = keychain_match_count(account, name)
        except (SecretUnavailable, OSError, AttributeError):
            return None
        if count > 1:
            raise SecretUnavailable(f"Multiple Keychain entries match service {name} and the current user. "
                                    "Resolve the duplicate entries locally in Keychain Access before retrying.")
        if count == 0:
            return None
        return run_secret_lookup(["/usr/bin/security", "find-generic-password", "-a", account, "-s", name, "-w"])
    if sys.platform.startswith("linux") and shutil.which("secret-tool"):
        return run_secret_lookup(["secret-tool", "lookup", "service", name, "account", account])
    return None


def shell_values(names):
    """Read selected exported variables from the user's login shell without logging output."""
    if not names:
        return {}
    try:
        shell = pwd.getpwuid(os.getuid()).pw_shell
        if not shell or not Path(shell).is_absolute():
            return {}
        marker = uuid.uuid4().hex
        script = ('import json,os,sys; '
                  'print(sys.argv[1]+json.dumps({n:os.environ[n] for n in sys.argv[2:] '
                  'if os.environ.get(n)}))')
        command = "exec " + " ".join(shlex.quote(arg) for arg in
                                     [sys.executable, "-c", script, marker, *names])
        result = subprocess.run([shell, "-lic", command], cwd=str(Path.home()),
                                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, timeout=15, check=False)
        if result.returncode or len(result.stdout) > 1024 * 1024:
            return {}
        position = result.stdout.rfind(marker.encode())
        if position < 0:
            return {}
        values = json.loads(result.stdout[position + len(marker):].splitlines()[0])
        return {name: values[name] for name in names
                if isinstance(values.get(name), str) and values[name]}
    except (OSError, KeyError, ValueError, subprocess.TimeoutExpired):
        return {}


def lookup(name):
    if sys.platform == "darwin":
        services = [SERVICE]
        if SERVICE != DEFAULT_SERVICE:
            services.append(DEFAULT_SERVICE)
        for service in dict.fromkeys(services):
            command = ["/usr/bin/security", "find-generic-password", "-a", name]
            if service:
                command += ["-s", service]
            command.append("-w")
            result = run_secret_lookup(command)
            if result is not None:
                return result
        raise SecretUnavailable(f"Native secret unavailable or ambiguous for Maven settings variable {name}. "
                                f"Use service {name} with the current system user as the Keychain account, "
                                "or export the variable in the default shell; see the installed MakeVN skill.")
    elif sys.platform.startswith("linux") and shutil.which("secret-tool"):
        command = ["secret-tool", "lookup", "service", SERVICE, "account", name]
    else:
        raise SecretUnavailable(f"Maven settings variable {name} is missing; native secret store unavailable. "
                         "See https://github.com/antonillos/makevn/blob/develop/skills/makevn/SKILL.md#native-secrets-for-maven-settings; never send secrets in chat or project config.")
    value = run_secret_lookup(command)
    if value is None:
        raise SecretUnavailable(f"Native secret unavailable for Maven settings variable {name}. "
                         f"Configure service {SERVICE}, account {name}; see the installed MakeVN skill.")
    return value


def run_secret_lookup(command):
    try:
        result = subprocess.run(command, capture_output=True, timeout=15, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode or not result.stdout:
        return None
    value = result.stdout.decode().removesuffix("\n")
    if not value or "\0" in value:
        return None
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
    missing = []
    for name in names:
        value = lookup_user_account(name)
        if value:
            environment[name] = value
        elif not environment.get(name):
            missing.append(name)
    environment.update(shell_values(missing))
    for name in missing:
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
              "see https://github.com/antonillos/makevn/blob/develop/skills/makevn/SKILL.md#native-secrets-for-maven-settings.", file=sys.stderr)
        sys.exit(1)
