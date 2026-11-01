#!/usr/bin/env python3
"""Inspect the selected Maven and enforce unconditional local version rules."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "jdk"))
from enforcer import UnresolvedSkipError, accepts, reactor_rules


def wrapper_version(executable):
    properties = Path(executable).parent / ".mvn/wrapper/maven-wrapper.properties"
    for line in properties.read_text().splitlines():
        if re.match(r"\s*distributionUrl\s*=", line):
            match = re.search(r"/apache-maven-(\d+(?:\.\d+)*)-bin\.(?:zip|tar\.gz)(?:$|[?#])", line.strip())
            if match:
                return match[1]
    raise ValueError("Cannot determine the wrapper Maven version from distributionUrl")


def installed_version(executable, cwd, java_home):
    environment = os.environ.copy()
    if java_home:
        environment["JAVA_HOME"] = java_home
        environment["PATH"] = str(Path(java_home) / "bin") + os.pathsep + environment.get("PATH", "")
    result = subprocess.run([executable, "--version"], cwd=cwd, env=environment,
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            timeout=20, check=False)
    output = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", result.stdout)
    match = re.search(r"^Apache Maven (\d+(?:\.\d+)*)(?=\s|$)", output, re.MULTILINE)
    if result.returncode or not match:
        raise ValueError("Cannot determine a stable Maven version from the selected executable")
    return match[1]


def command_properties(arguments):
    properties = {}
    arguments = iter(arguments)
    for argument in arguments:
        if argument == "--":
            break
        if argument in ("-D", "--define"):
            value = next(arguments, "")
        elif argument.startswith("-D"):
            value = argument[2:]
        elif argument.startswith("--define="):
            value = argument[len("--define="):]
        else:
            continue
        name, separator, value = value.partition("=")
        if name:
            properties[name] = value if separator else "true"
    return properties


def inspect(executable, base, cwd, java_home, checking=False, arguments=()):
    deferred_modules = []
    requirements = reactor_rules(Path(base) / "pom.xml", rule_name="requireMavenVersion",
                                 deferred_modules=deferred_modules,
                                 user_properties=command_properties(arguments))
    deferred = ("; unresolved module paths deferred to Maven: " + ", ".join(dict.fromkeys(deferred_modules))
                if deferred_modules else "")
    if checking and not requirements:
        return "No locally resolved Maven version constraint" + deferred
    selected = shutil.which(executable) or executable
    wrapper = Path(selected).name == "mvnw"
    if wrapper and not checking:
        version = wrapper_version(selected)
        source = "wrapper declaration; runtime not probed"
    else:
        version = installed_version(selected, cwd, java_home)
        source = "installed"
    required = " & ".join(requirements) or "none detected locally"
    if not all(accepts(rule, version, java=False) for rule in requirements):
        raise ValueError(f"Maven {version} at {selected} does not satisfy requireMavenVersion: {required}. "
                         "Install/select a compatible Maven using .tool-versions or the wrapper; do not bypass Enforcer.")
    status = "compatible" if requirements else "not constrained locally"
    return f"{version} ({source}); executable: {selected}; required: {required}; {status}" + deferred


def main(args):
    mode, executable, base, cwd, java_home, *arguments = args
    try:
        message = inspect(executable, base, cwd, java_home, checking=mode == "check", arguments=arguments)
        if mode != "check":
            print(message)
        return 0
    except UnresolvedSkipError as error:
        if mode != "check":
            print("Maven version requirements depend on command properties: " + str(error) +
                  ". Compatibility will be checked with the selected command's properties.")
            return 0
        print("Maven version unresolved or incompatible: " + str(error), file=sys.stderr)
        return 1
    except (ValueError, OSError, ET.ParseError, subprocess.TimeoutExpired) as error:
        print("Maven version unresolved or incompatible: " + str(error),
              file=sys.stderr if mode == "check" else sys.stdout)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
