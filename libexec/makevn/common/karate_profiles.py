"""Conservatively discover literal Spring profiles in Karate CI workflows."""
from pathlib import Path
import re
import sys

VALUE = r'''(?:"([^"]*)"|'([^']*)'|([^\s"']+))'''
PATTERN = re.compile(r'(?:--spring\.profiles\.active=|\bSPRING_PROFILES_ACTIVE\s*[:=]\s*)' + VALUE)
VALID = re.compile(r'[A-Za-z0-9_.-]+(?:,[A-Za-z0-9_.-]+)*\Z')


def detect(repo):
    found = {}
    unresolved = []
    for path in sorted((repo / '.github/workflows').glob('*')):
        if path.suffix not in ('.yml', '.yaml') or not path.is_file():
            continue
        text = path.read_text(errors='replace')
        if 'karate' not in (path.name + text).lower():
            continue
        for number, line in enumerate(text.splitlines(), 1):
            line = line.split('#', 1)[0]
            for match in PATTERN.finditer(line):
                value = next(group for group in match.groups() if group is not None).strip()
                source = f'{path.relative_to(repo)}:{number}'
                if VALID.fullmatch(value):
                    found.setdefault(value, []).append(source)
                else:
                    unresolved.append(source)
    status = 'missing'
    profiles = ''
    if found or unresolved:
        status = 'resolved' if len(found) == 1 and not unresolved else 'ambiguous'
    if status == 'resolved':
        profiles = next(iter(found))
    sources = [source for locations in found.values() for source in locations] + unresolved
    candidates = [f'{value} ({", ".join(locations)})' for value, locations in found.items()]
    candidates += [f'dynamic/unrecognized value ({source})' for source in unresolved]
    return dict(profiles=profiles, status=status, source='; '.join(sources), candidates='; '.join(candidates))


if __name__ == '__main__':
    for key, value in detect(Path(sys.argv[1])).items():
        print(f'{key}\t{value}')
