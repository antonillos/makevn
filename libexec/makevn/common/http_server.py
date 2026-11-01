#!/usr/bin/env python3
"""Detect HTTP server dependencies declared by Maven projects."""
import os
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET


SERVER_ARTIFACT = re.compile(
    r"spring-boot-starter-(web[^<]*|actuator)|"
    r"quarkus-(rest(-jackson|-jsonb)?|resteasy(-reactive)?(-jackson|-jsonb)?|vertx-http)|"
    r"micronaut-http-server[^<]*"
)


def has_http_server(base):
    for directory, children, files in os.walk(base):
        children[:] = sorted(name for name in children
                             if name not in {".git", ".makevn", "target", "node_modules"})
        if "pom.xml" not in files:
            continue
        try:
            root = ET.parse(Path(directory) / "pom.xml").getroot()
        except (ET.ParseError, OSError):
            continue
        containers = [root] + [profile for profile in root.findall("./{*}profiles/{*}profile")
                               if profile.findtext("./{*}activation/{*}activeByDefault", "").strip().lower() == "true"]
        for dependency in (dependency for container in containers
                           for dependency in container.findall("./{*}dependencies/{*}dependency")):
            scope = dependency.findtext("{*}scope", "compile").strip()
            artifact = dependency.findtext("{*}artifactId", "").strip()
            if scope in {"compile", "runtime", "provided", "system"} and SERVER_ARTIFACT.fullmatch(artifact):
                return True
    return False


if __name__ == "__main__":
    sys.exit(0 if has_http_server(sys.argv[1]) else 1)
