"""Inspect test filters on an owner's literal local or cached parent chain."""
import os
from pathlib import Path
import re


def read(pom):
    from changes_scope import parse
    return parse(pom.read_text())


def coordinates(root):
    return tuple((root.findtext(key) or root.findtext('parent/' + key, '')).strip()
                 for key in ['groupId', 'artifactId', 'version'])


def cached_parent(expected):
    if not all(re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_.-]*', value) and '..' not in value for value in expected):
        raise ValueError('unresolved test-inventory parent coordinates')
    repository = Path.home() / '.m2/repository'
    settings = Path(os.environ.get('MAVEN_CONFIG', str(Path.home() / '.m2'))) / 'settings.xml'
    if settings.is_file():
        location = read(settings).findtext('localRepository')
        if location:
            location = location.replace('${user.home}', str(Path.home()))
            if '${' in location or not Path(location).is_absolute():
                raise ValueError('unresolved test-inventory local repository')
            repository = Path(location)
    group, artifact, version = expected
    return repository / group.replace('.', '/') / artifact / version / (artifact + '-' + version + '.pom')


def models(base, owner):
    pom = (base / owner / 'pom.xml').resolve()
    seen = set()
    local = True
    while True:
        if pom in seen or len(seen) >= 32:
            raise ValueError('cyclic or excessively deep test-inventory parent chain')
        seen.add(pom)
        root = read(pom)
        yield root
        parent = root.find('parent')
        if parent is None:
            return
        expected = tuple(parent.findtext(key, '').strip() for key in ['groupId', 'artifactId', 'version'])
        relative = parent.findtext('relativePath', '../pom.xml').strip()
        candidate = (pom.parent / relative).resolve() if local and relative else None
        if candidate is not None and candidate.is_dir():
            candidate /= 'pom.xml'
        if candidate is not None and candidate.is_file() and coordinates(read(candidate)) == expected:
            pom = candidate
            continue
        pom = cached_parent(expected)
        local = False
        if not pom.is_file() or coordinates(read(pom)) != expected:
            raise ValueError('test-inventory parent is unavailable in the local cache')


def validate(base, owner='.'):
    for root in models(base, owner):
        for plugin in root.findall('.//plugin'):
            if plugin.findtext('artifactId') not in {'maven-surefire-plugin', 'maven-failsafe-plugin'}:
                continue
            if any(plugin.find('.//' + tag) is not None
                   for tag in ['includes', 'excludes', 'includesFile', 'excludesFile']):
                raise ValueError('configured test inventory is unknown; complete owner suite required')
