#!/usr/bin/env python3
"""Detect HTTP server dependencies declared by Maven projects."""
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET


SERVER_ARTIFACT = re.compile(
    r"spring-boot-starter-(web[^<]*|actuator)|"
    r"quarkus-(rest(-jackson|-jsonb)?|resteasy(-reactive)?(-jackson|-jsonb)?|vertx-http)|"
    r"micronaut-http-server[^<]*"
)


def has_http_server(base, actuator_only=False):
    pending = [Path(base) / "pom.xml"]
    visited = set()
    while pending:
        pom = pending.pop().resolve()
        if pom in visited:
            continue
        visited.add(pom)
        try:
            root = ET.parse(pom).getroot()
        except (ET.ParseError, OSError):
            continue
        containers = [root] + [profile for profile in root.findall("./{*}profiles/{*}profile")
                               if profile.findtext("./{*}activation/{*}activeByDefault", "").strip().lower() == "true"]
        for container in containers:
            for module in container.findall("./{*}modules/{*}module"):
                name = (module.text or "").strip()
                if name and "${" not in name:
                    candidate = pom.parent / name
                    pending.append(candidate if candidate.name == "pom.xml" else candidate / "pom.xml")
            for dependency in container.findall("./{*}dependencies/{*}dependency"):
                scope = dependency.findtext("{*}scope", "compile").strip()
                artifact = dependency.findtext("{*}artifactId", "").strip()
                match = artifact == "spring-boot-starter-actuator" if actuator_only else SERVER_ARTIFACT.fullmatch(artifact)
                if scope in {"compile", "runtime", "provided", "system"} and match:
                    return True
    return False


if __name__ == "__main__":
    sys.exit(0 if has_http_server(sys.argv[1], "--actuator" in sys.argv[2:]) else 1)
