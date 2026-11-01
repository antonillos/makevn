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


def managed_scopes(pom, root, seen=frozenset()):
    if pom in seen:
        return {}
    scopes = {}
    parent = root.find("{*}parent")
    if parent is not None:
        relative = parent.findtext("{*}relativePath", "../pom.xml").strip()
        candidate = (pom.parent / relative).resolve() if relative else None
        if candidate is not None and candidate.is_dir():
            candidate = candidate / "pom.xml"
        if candidate is None or not candidate.is_file():
            group = parent.findtext("{*}groupId", "").strip()
            artifact = parent.findtext("{*}artifactId", "").strip()
            version = parent.findtext("{*}version", "").strip()
            if all(re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]*", part) and ".." not in part
                   for part in (group, artifact, version)):
                candidate = Path.home() / ".m2/repository" / group.replace(".", "/") / artifact / version / f"{artifact}-{version}.pom"
        if candidate is not None and candidate.is_file():
            try:
                scopes.update(managed_scopes(candidate, ET.parse(candidate).getroot(), seen | {pom}))
            except (ET.ParseError, OSError):
                pass
    for dependency in root.findall("./{*}dependencyManagement/{*}dependencies/{*}dependency"):
        group = dependency.findtext("{*}groupId", "").strip()
        artifact = dependency.findtext("{*}artifactId", "").strip()
        scope = dependency.findtext("{*}scope", "").strip()
        if scope:
            scopes[(group, artifact)] = scope
    return scopes


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
        scopes = managed_scopes(pom, root)
        for container in containers:
            for module in container.findall("./{*}modules/{*}module"):
                name = (module.text or "").strip()
                if name and "${" not in name:
                    candidate = pom.parent / name
                    pending.append(candidate if candidate.name == "pom.xml" else candidate / "pom.xml")
            for dependency in container.findall("./{*}dependencies/{*}dependency"):
                artifact = dependency.findtext("{*}artifactId", "").strip()
                group = dependency.findtext("{*}groupId", "").strip()
                scope = dependency.findtext("{*}scope", "").strip() or scopes.get((group, artifact), "compile")
                match = artifact == "spring-boot-starter-actuator" if actuator_only else SERVER_ARTIFACT.fullmatch(artifact)
                if scope in {"compile", "runtime", "provided", "system"} and match:
                    return True
    return False


if __name__ == "__main__":
    sys.exit(0 if has_http_server(sys.argv[1], "--actuator" in sys.argv[2:]) else 1)
