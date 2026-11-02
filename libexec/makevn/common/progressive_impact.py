"""Static selection with additive, conservatively attributed runtime observations."""
import contextlib
import fcntl
import io
import os
import re
from pathlib import Path
import subprocess
import sys
import tempfile
import urllib.parse
import xml.etree.ElementTree as ET

import test_impact as impact
import reactor_test_impact as reactor
from test_inventory import validate as validate_test_inventory

KIND = 'progressive-v1'
CONDITIONAL = {'Disabled', 'EnabledOnOs', 'DisabledOnOs', 'EnabledOnJre', 'DisabledOnJre',
               'EnabledForJreRange', 'DisabledForJreRange', 'assumeTrue', 'assumeFalse',
               'EnabledIf', 'DisabledIf', 'EnabledIfSystemProperty', 'DisabledIfSystemProperty',
               'EnabledIfEnvironmentVariable', 'DisabledIfEnvironmentVariable'}
UNCERTAIN = CONDITIONAL | {'SpringBootTest', 'ContextConfiguration', 'Autowired', 'Inject',
                           'ExtendWith', 'RunWith', 'Mock', 'MockBean', 'Mockito'}


def path(repo):
    return impact.state(repo) / 'progressive.json'


def environment(java):
    value = impact.context(java)
    # The runner sets these to the explicitly selected JDK before invoking Maven.
    for name in ['JAVA_HOME', 'PATH']:
        value.get('environment', {}).pop(name, None)
    return value


def snapshot(repo, base, java):
    owners = reactor.modules(base)
    if owners:
        reactor.validate(base, owners)
    else:
        impact.validate_layout(base)
    return {'version': impact.VERSION, 'kind': reactor.KIND if owners else KIND,
            'modules': owners, 'repo': str(repo), 'base': str(base),
            'head': subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], stderr=subprocess.DEVNULL).decode().strip(),
            'inputs': reactor.inputs(repo, base, owners), 'context': environment(java),
            'facts': reactor.facts(base, owners, java) if owners else impact.facts(base, java),
            'observations': {}, 'skipped': {}, 'jars': {}}


def tests(parsed):
    return {item['class'] for source, item in parsed.items() if reactor.is_source(source, 'test')
            and (item.get('name', item['class']).rsplit('.', 1)[-1].startswith(('IT', 'Test')) or
                 item['class'].endswith(('Test', 'Tests', 'IT', 'ITCase', 'TestCase')) or
                 {'Test', 'ParameterizedTest', 'RepeatedTest', 'TestFactory', 'TestTemplate'}.intersection(item['names']))}


def constraints(value):
    sources = {(Path(value['base']) / source).relative_to(value['repo']).as_posix()
               for source in value['facts']}
    return {key: value[key] for key in ['base', 'head', 'context', 'kind']} | {
        'modules': value.get('modules', []),
        'inputs': {key: sha for key, sha in value['inputs'].items() if key not in sources},
        'shapes': {key: item['shape'] for key, item in value['facts'].items()}}


def load(repo):
    value = impact.sealed_load(path(repo))
    if value.get('kind') not in {KIND, reactor.KIND}:
        raise ValueError('unknown progressive map format')
    return value


def reusable(previous, current):
    return constraints(previous) == constraints(current) and all(
        Path(name).is_file() and impact.digest(Path(name)) == sha for name, sha in previous['jars'].items())


@contextlib.contextmanager
def locked(repo):
    directory = impact.state(repo)
    directory.mkdir(parents=True, exist_ok=True)
    with (directory / 'progressive.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def initialize(repo, base, java, write=True):
    current = snapshot(repo, base, java)
    with locked(repo) if write else contextlib.nullcontext():
        try:
            previous = load(repo)
            if reusable(previous, current):
                current['observations'] = previous['observations']
                current['jars'] = previous['jars']
                current['skipped'] = previous.get('skipped', {})
        except (OSError, ValueError, KeyError, TypeError):
            pass
        if write:
            impact.sealed_save(path(repo), current)
    return current


def baseline(repo, base, java, parsed, paths, reference):
    previous = dict(parsed)
    with tempfile.TemporaryDirectory(prefix='makevn-static-baseline-') as folder:
        root = Path(folder)
        for source in paths:
            relative = (repo / source).relative_to(base).as_posix()
            content = subprocess.check_output(['git', '-C', str(repo), 'show', reference + ':' + source],
                                              stderr=subprocess.DEVNULL)
            target = root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(content)
        owners = sorted({item['owner'] for item in parsed.values() if 'owner' in item})
        previous.update(reactor.facts(root, owners, java) if owners else impact.facts(root, java))
    return previous


def consumers(parsed, changed):
    from collections import defaultdict, deque
    aliases, edges, production = defaultdict(set), defaultdict(set), set()
    for source, item in parsed.items():
        for alias in item.get('declared', [item['class'].rsplit('.', 1)[-1]]):
            aliases[alias].add(item['class'])
        if reactor.is_source(source, 'main'):
            production.add(item['class'])
    seeds = set(changed)
    for item in parsed.values():
        name = item['class']
        if (impact.DYNAMIC | UNCERTAIN).intersection(item['names']):
            seeds.add(name)
        for reference in item['names']:
            for target in aliases[reference]:
                edges[target].add(name)
                # Without Java attribution, an implementation may be consumed
                # through an interface/base class. Retain connected production
                # types in both directions rather than missing that dispatch.
                if name in production and target in production:
                    edges[name].add(target)
    pending, affected = deque(seeds), set(seeds)
    while pending:
        for name in edges[pending.popleft()] - affected:
            affected.add(name)
            pending.append(name)
    return affected


def narrow(repo, base, owner, paths, changed_tests, reference, cache=None):
    collect_fallbacks = cache is not None
    try:
        if cache is None:
            cache = {}
        java = Path(os.environ.get('MAKEVN_TEST_IMPACT_JAVA', 'java'))
        if 'current' not in cache:
            cache['current'] = snapshot(repo, base, java)
        current = cache['current']
        if owner not in (current['modules'] or ['.']):
            raise ValueError('unknown reactor owner')
        validate_test_inventory(base, owner)
        allowed = {source for source in paths if source.endswith('.java') and
                   ('/src/main/java/' in '/' + source or '/src/test/java/' in '/' + source)}
        from changes_scope import non_verification_path
        if not allowed or any(source not in allowed and not non_verification_path(source) for source in paths):
            raise ValueError('resource/build/unknown changes require the complete suite')
        actual = subprocess.check_output(['git', '-C', str(repo), 'diff', '--name-only', '-z', reference, '--']).split(b'\0')
        if any(os.fsdecode(source) not in allowed and not non_verification_path(os.fsdecode(source))
               for source in actual if source):
            raise ValueError('unclassified changes require the complete suite')
        try:
            stored = load(repo)
        except (OSError, ValueError, KeyError, TypeError):
            stored = None
        if stored is not None:
            changed_inputs = {key for key in stored['inputs'].keys() | current['inputs'].keys()
                              if stored['inputs'].get(key) != current['inputs'].get(key)}
            if changed_inputs - allowed:
                raise ValueError('configuration/resources or unclassified inputs changed')
        if 'previous' not in cache:
            cache['previous'] = baseline(repo, base, java, current['facts'], allowed, reference)
        previous = cache['previous']
        changed, changed_test_classes = set(), set()
        parsed = {key: dict(item) for key, item in current['facts'].items()}
        for source in allowed:
            relative = (repo / source).relative_to(base).as_posix()
            before, after = previous[relative], parsed[relative]
            if before['shape'] != after['shape']:
                raise ValueError('declarations/imports/helpers changed')
            if reactor.is_source(relative, 'test'):
                if after['class'] not in tests(current['facts']):
                    raise ValueError('test helper changed')
                changed_test_classes.add(after['class'])
            else:
                if impact.state_writes_changed(before, after):
                    raise ValueError('changed method may write shared state')
                if (impact.DYNAMIC | impact.UNSAFE_CHANGE).intersection(set(before['names']) | set(after['names'])):
                    raise ValueError('changed method has dynamic/global effects')
                changed.add(after['class'])
            parsed[relative]['names'] = sorted(set(before['names']) | set(after['names']))
        affected = consumers(parsed, changed | changed_test_classes)
        selected = changed_test_classes | {reactor.identity(current, owner, name) for name in changed_tests} | (affected & tests(parsed))
        observations, skipped = {}, set()
        try:
            stored = load(repo)
            if reusable(stored, current):
                observations = stored['observations']
                skipped = set(stored.get('skipped', {}))
        except (OSError, ValueError, KeyError, TypeError):
            pass
        selected.update(skipped)
        selected.update(name for name, loaded in observations.items() if affected.intersection(loaded))
        if current['kind'] == KIND and (impact.state(repo) / 'map.json').exists():
            with contextlib.redirect_stderr(io.StringIO()):
                selected.update(impact.narrow(repo, base, owner, paths, changed_tests) or set())
        selected = reactor.local_names(current, selected, owner)
        if not selected:
            raise ValueError('no statically known tests; complete suite retained')
        print('Test impact: static dependencies plus additive runtime observations; ' +
              str(len(selected)) + '/' + str(len(reactor.local_names(current, tests(parsed), owner))) +
              ' classes selected for ' + owner, file=sys.stderr)
        return selected
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError, ET.ParseError) as error:
        if collect_fallbacks:
            cache.setdefault('fallbacks', {}).setdefault(str(error), set()).add(owner)
        else:
            print('Test impact: complete suite; ' + str(error), file=sys.stderr)
        return None


def report_fallbacks(cache):
    for reason, owners in sorted(cache.get('fallbacks', {}).items()):
        print('Test impact: complete suites for ' + ', '.join(sorted(owners)) + '; ' + reason, file=sys.stderr)

def enrich(repo, base, java, before, stamp, traces):
    after = snapshot(repo, base, java)
    if before['inputs'] != after['inputs'] or constraints(before) != constraints(after):
        raise ValueError('inputs changed during execution; runtime observations discarded')
    active, skipped = set(), {}
    for owner in after['modules'] or ['.']:
        for plugin in ['surefire-reports', 'failsafe-reports']:
            for report in (base / owner / 'target' / plugin).glob('TEST-*.xml'):
                if report.stat().st_mtime_ns < stamp.stat().st_mtime_ns:
                    continue
                for case in ET.parse(report).getroot().iter('testcase'):
                    if case.find('failure') is not None or case.find('error') is not None:
                        raise ValueError('failed reports cannot enrich the map')
                    name = reactor.identity(after, owner, case.get('classname', '').split('$')[0])
                    if case.find('skipped') is None:
                        active.add(name)
                    else:
                        skipped[name] = case.find('skipped').get('message', 'no reason reported')
    loaded, jars = set(), {}
    for trace in traces.glob('*.log'):
        for line in trace.read_text(errors='replace').splitlines():
            match = re.search(r'\[class,load\]\s+(\S+)\s+source:\s+(.+)', line)
            if not match:
                continue
            loaded.add(match[1].split('$')[0])
            if match[2].startswith('file:'):
                jar = Path(urllib.parse.unquote(urllib.parse.urlparse(match[2]).path))
                if jar.suffix == '.jar' and jar.is_file() and not jar.is_relative_to(base / 'target'):
                    jars[str(jar)] = impact.digest(jar)
    loaded = {item['class'] for item in after['facts'].values()
              if item.get('name', item['class']) in loaded}
    active &= loaded & tests(after['facts'])
    if not active and not skipped:
        return
    production = {item['class'] for source, item in after['facts'].items() if reactor.is_source(source, 'main')}
    dependencies = loaded & production
    with locked(repo):
        try:
            previous = load(repo)
            if reusable(previous, after):
                after['observations'] = previous['observations']
                after['jars'] = previous['jars']
                after['skipped'] = previous.get('skipped', {})
        except (OSError, ValueError, KeyError, TypeError):
            pass
        for name in active:
            after['observations'][name] = sorted(set(after['observations'].get(name, [])) | dependencies)
        after['jars'].update(jars)
        after['skipped'].update({name: reason for name, reason in skipped.items() if name in tests(after['facts'])})
        impact.sealed_save(path(repo), after)
    print('Test impact: enriched ' + str(len(active)) +
          ' test classes with execution-wide loaded-class supersets (additive only)', file=sys.stderr)


def absorb_isolated(repo, base, java, evidence):
    current = initialize(repo, base, java, False)
    for name, dependencies in evidence['records'].items():
        current['observations'][name] = sorted(set(current['observations'].get(name, [])) | set(dependencies))
    current['skipped'].update(evidence.get('skipped', {}))
    with locked(repo):
        try:
            previous = load(repo)
            if reusable(previous, current):
                for name, dependencies in previous['observations'].items():
                    current['observations'][name] = sorted(set(current['observations'].get(name, [])) | set(dependencies))
        except (OSError, ValueError, KeyError, TypeError):
            pass
        current['jars'].update(evidence['jars'])
        impact.sealed_save(path(repo), current)


if __name__ == '__main__':
    try:
        command, repo, base, java = sys.argv[1:]
        value = initialize(Path(repo).resolve(), Path(base).resolve(), Path(java), command in {'init', 'init-summary'})
        if command == 'init-summary':
            summary = 'static map updated · ' + str(len(tests(value['facts']))) + ' test classes'
            if value['observations']:
                summary += ' · ' + str(len(value['observations'])) + ' observed classes retained'
            print(summary)
        else:
            print('Test impact: static map ' + ('saved' if command == 'init' else 'preview') +
                  '; ' + str(len(tests(value['facts']))) + ' candidate test classes; no Maven or tests executed; ' +
                  str(len(value['observations'])) + ' observed classes retained')
    except (OSError, ValueError, KeyError, subprocess.SubprocessError, ET.ParseError) as error:
        print('Cannot initialize static impact: ' + str(error), file=sys.stderr)
        sys.exit(1)
