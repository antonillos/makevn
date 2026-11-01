"""Resolve published parent properties without running Maven or project code."""
from functools import lru_cache
import os
from pathlib import Path
import re
import tempfile
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET


def read_model(data):
    root = ET.fromstring(data)
    for node in root.iter():
        node.tag = node.tag.rsplit("}", 1)[-1]
    return root


def repository_settings():
    repository = Path.home() / ".m2/repository"
    settings = Path.home() / ".m2/settings.xml"
    central = True
    if settings.is_file():
        root = read_model(settings.read_bytes())
        location = root.findtext("localRepository")
        if location:
            repository = Path(location.replace("${user.home}", str(Path.home()))).expanduser()
        central = root.findtext("offline", "false").strip().lower() != "true" and not root.findall("mirrors/mirror")
    return repository, central


def artifact_path(parent):
    coordinates = [parent.findtext(key, "").strip() for key in ("groupId", "artifactId", "version")]
    if not all(re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]*", value) and ".." not in value
               for value in coordinates):
        raise ValueError("Cannot resolve parent POM with missing or nonliteral coordinates")
    group, artifact, version = coordinates
    return Path(*group.split(".")) / artifact / version / f"{artifact}-{version}.pom"


@lru_cache(maxsize=64)
def published_model(relative):
    repository, central = repository_settings()
    local = repository / relative
    if local.is_file():
        return read_model(local.read_bytes())
    if not central:
        raise ValueError("Parent POM is not cached locally; offline/mirrored Maven settings prevent "
                         "direct Central inspection: " + str(relative))
    cache = Path(os.environ.get("XDG_CACHE_HOME", str(Path.home() / ".cache"))) / "makevn/parent-poms" / relative
    if cache.is_file():
        return read_model(cache.read_bytes())
    try:
        with urllib.request.urlopen("https://repo.maven.apache.org/maven2/" + relative.as_posix(), timeout=5) as response:
            data = response.read(2_000_001)
        if len(data) > 2_000_000:
            raise ValueError("Parent POM exceeds the inspection size limit")
        root = read_model(data)
    except (OSError, urllib.error.URLError, ET.ParseError) as error:
        raise ValueError("Cannot inspect parent POM " + str(relative) + ": " + str(error)) from error
    cache.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=cache.parent, delete=False) as output:
        output.write(data)
        temporary = Path(output.name)
    temporary.replace(cache)
    return root


def inherited_properties(root, seen=frozenset()):
    parent = root.find("parent")
    if parent is None:
        return {}
    relative = artifact_path(parent)
    if relative in seen or len(seen) >= 16:
        raise ValueError("Cyclic or excessively deep published parent POM hierarchy")
    model = published_model(relative)
    properties = inherited_properties(model, seen | {relative})
    properties.update({node.tag: node.text or "" for node in model.findall("properties/*")})
    return properties
