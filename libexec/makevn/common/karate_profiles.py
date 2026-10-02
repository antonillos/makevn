"""Conservatively discover literal Spring profiles in Karate CI workflows."""
from pathlib import Path
import re
import sys

VALUE = r'''(?:"([^"]*)"|'([^']*)'|([^\s"']+))'''
PATTERN = re.compile(r'(?:--spring\.profiles\.active=|\bSPRING_PROFILES_ACTIVE\s*[:=]\s*)' + VALUE)
VALID = re.compile(r'[A-Za-z0-9_.-]+(?:,[A-Za-z0-9_.-]+)*\Z')


KARATE_TOKEN = re.compile(r'(?<![a-z0-9])karate(?![a-z0-9])', re.I)
KARATE_COMMAND = re.compile(
    r'^\s*(?:-\s*)?(?:run:\s*)?(?:\./)?(?:makevn\s+karate-(?:test|all)\b'
    r'|mvnw?\b[^\n]*\s-f\s+[\"\']?[^\s\"\']*karate/pom\.xml)', re.I)


def labelled_karate(lines):
    for _, line in lines:
        label = re.match(r'^\s*(?:-\s*)?(?:name|uses):\s*(.*)', line)
        if (label and KARATE_TOKEN.search(label[1])) or KARATE_COMMAND.search(line):
            return True
    return False


def karate_scope_lines(text):
    """Read ordinary indentation-based job/step scopes, never YAML expressions.

    Unrecognized layouts are ignored rather than borrowing a sibling job's
    profiles. Workflow filenames/descriptions alone cannot identify a job.
    """
    lines = [(number, line.split('#', 1)[0])
             for number, line in enumerate(text.splitlines(), 1)]
    jobs = next((i for i, (_, line) in enumerate(lines)
                 if re.match(r'^jobs:\s*$', line)), None)
    if jobs is None:
        return []
    body = []
    for entry in lines[jobs + 1:]:
        line = entry[1]
        if line.strip() and not line.startswith(' '):
            break
        if line.strip():
            body.append(entry)
    if not body:
        return []
    indent = len(body[0][1]) - len(body[0][1].lstrip())
    starts = [i for i, (_, line) in enumerate(body)
              if re.match(r'^ {' + str(indent) + r'}[\w.\-\"\']+:', line)]
    eligible = []
    for start, end in zip(starts, starts[1:] + [len(body)]):
        job = body[start:end]
        child_indent = min((len(line) - len(line.lstrip()) for _, line in job[1:]), default=indent + 2)
        steps_at = next((i for i, (_, line) in enumerate(job)
                         if re.match(r'^ {' + str(child_indent) + r'}steps:', line)), len(job))
        steps_end = next((i for i in range(steps_at + 1, len(job))
                          if re.match(r'^ {' + str(child_indent) + r'}[\w.-]+:', job[i][1])), len(job))
        prefix = job[:steps_at] + job[steps_end:]
        step_lines = job[steps_at + 1:steps_end]
        if steps_at < len(job) and not re.match(r'^\s*steps:\s*$', job[steps_at][1]):
            step_lines = []  # Inline/aliased step layouts are not evaluated.
        step_indent = next((len(line) - len(line.lstrip()) for _, line in step_lines
                            if line.lstrip().startswith('- ')), None)
        step_starts = [i for i, (_, line) in enumerate(step_lines)
                       if step_indent is not None
                       and line.startswith(' ' * step_indent + '- ')]
        steps = [step_lines[a:b] for a, b in
                 zip(step_starts, step_starts[1:] + [len(step_lines)])]
        job_id = job[0][1].strip().split(':', 1)[0].strip("\"'")
        if not KARATE_TOKEN.search(job_id) and not labelled_karate(prefix + [item for step in steps for item in step]):
            continue
        eligible.extend(prefix)
        for step in steps:
            startup = any(re.search(r'\bjava\b.*\s-jar\b|\bmakevn\s+run-app|name:.*start.*application', line, re.I)
                          for _, line in step)
            if labelled_karate(step) or startup:
                eligible.extend(step)
    # Workflow-level env is inherited by identified Karate jobs. Other top-level
    # keys (descriptions, unrelated command strings) are not profile evidence.
    if eligible:
        global_env = False
        for entry in lines[:jobs]:
            line = entry[1]
            if line.strip() and not line.startswith(' '):
                global_env = bool(re.match(r'^env:\s*$', line))
            if global_env:
                eligible.append(entry)
    return eligible


def detect(repo):
    found = {}
    unresolved = []
    for path in sorted((repo / '.github/workflows').glob('*')):
        if path.suffix not in ('.yml', '.yaml') or not path.is_file():
            continue
        text = path.read_text(errors='replace')
        for number, line in karate_scope_lines(text):
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
