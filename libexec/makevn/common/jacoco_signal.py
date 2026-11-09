"""Inspect cached parent declarations without executing Maven or guessing activation."""
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'jdk'))
from parent_properties import artifact_path, read_model, repository_settings


def inherited_declaration(pom, seen=None):
    seen = set() if seen is None else seen
    pom = Path(pom).resolve()
    if pom in seen or len(seen) >= 16:
        return None
    seen.add(pom)
    root = read_model(pom.read_bytes())
    parent = root.find('parent')
    if parent is None:
        return None
    relative = parent.findtext('relativePath', '../pom.xml')
    candidate = (pom.parent / relative).resolve() if relative else None
    if candidate is not None and candidate.is_file():
        local = read_model(candidate.read_bytes())
        if any(local.findtext(key) != parent.findtext(key) for key in ('groupId', 'artifactId', 'version')):
            candidate = None
    if candidate is None or not candidate.is_file():
        repository, _ = repository_settings()
        candidate = repository / artifact_path(parent)
    if not candidate.is_file():
        return None
    model = read_model(candidate.read_bytes())
    if any(p.findtext('artifactId') == 'jacoco-maven-plugin' for p in model.findall('.//plugin')):
        return candidate.name
    return inherited_declaration(candidate, seen)


if __name__ == '__main__':
    try:
        result = inherited_declaration(Path(sys.argv[1]) / 'pom.xml')
        if result:
            print('plugin declared in parent ' + result + '; profile activation and agent execution not verified')
    except (OSError, ValueError, ET.ParseError):
        pass  # Inspection limits retain the caller's explicit unknown signal.
