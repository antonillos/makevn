"""Conservative test-class selection from isolated JVM class-loading evidence."""
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import urllib.parse
import xml.etree.ElementTree as ET
import zipfile

VERSION = 4
DYNAMIC = {'forName', 'loadClass', 'getDeclaredMethod', 'getDeclaredMethods',
           'getDeclaredConstructor', 'getDeclaredConstructors', 'getMethod', 'getMethods',
           'getConstructor', 'getConstructors', 'ServiceLoader', 'MethodHandle',
           'MethodHandles', 'invoke', 'invokeExact', 'ClassLoader', 'getField', 'getDeclaredField',
           'getFields', 'getDeclaredFields', 'getDeclaredClasses', 'newProxyInstance',
           'getResource', 'getResourceAsStream', 'Files', 'FileInputStream', 'FileReader',
           'RandomAccessFile', 'FileChannel', 'ProcessBuilder', 'Runtime', 'exec'}
UNSAFE_CHANGE = {'System', 'setDefault', 'setProperty', 'clearProperty', 'setProperties',
                 'setOut', 'setErr', 'setSecurityManager', 'FileWriter', 'FileOutputStream',
                 'Socket', 'URLConnection'}


def digest(path):
    if path.is_symlink():
        raise ValueError('linked evidence input: ' + str(path))
    return hashlib.sha256(path.read_bytes()).hexdigest()


def state(repo):
    return repo / '.makevn/test-impact'


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode='w', dir=path.parent, delete=False) as stream:
        json.dump(value, stream, sort_keys=True)
    Path(stream.name).replace(path)


def inputs(repo, base):
    names = subprocess.check_output(['git', '-C', str(repo), 'ls-files', '-z',
                                     '--cached', '--others', '--exclude-standard']).split(b'\0')
    result = {}
    for name in filter(None, names):
        relative = os.fsdecode(name)
        if any(part in {'.git', '.makevn', 'target'} for part in Path(relative).parts):
            continue
        if relative.startswith('docs/') or Path(relative).suffix in {'.md', '.rst', '.adoc'}:
            continue
        path = repo / relative
        result[relative] = digest(path) if path.is_file() else '<deleted>'
    for name in ['config', 'profile.env']:
        path = repo / '.makevn' / name
        result['.makevn/' + name] = digest(path) if path.is_file() else ''
    # Ignored runtime resources also affect the observed test-to-class mapping.
    for root in [base / 'src/main/resources', base / 'src/test/resources', repo / '.mvn']:
        for path in root.rglob('*'):
            if path.is_file():
                result[path.relative_to(repo).as_posix()] = digest(path)
    return result


def context(java):
    release = java.resolve().parent.parent / 'release'
    settings = Path(os.environ.get('MAVEN_CONFIG', str(Path.home() / '.m2'))) / 'settings.xml'
    environment = {name: value for name, value in os.environ.items()
                   if not name.startswith(('MAKEVN_', 'BASH_FUNC_', 'BASHCOV_', 'RTK_')) and
                   name not in {'_', 'SHLVL', 'PWD', 'OLDPWD', 'CODEX_TOOL_CALL_ID',
                                'SHELLOPTS', 'BASHOPTS', 'BASH_XTRACEFD'}}
    return {'java': str(java.resolve()), 'release': digest(release),
            'settings': digest(settings) if settings.is_file() else '',
            'environment': {name: hashlib.sha256(value.encode()).hexdigest()
                            for name, value in environment.items()}}


def repository_models():
    root = Path.home() / '.m2/repository'
    return {str(path): model_digest(path) for path in [*root.rglob('*.pom'), *root.rglob('maven-metadata*.xml')]}


def model_digest(path):
    if not path.name.startswith('maven-metadata'):
        return digest(path)
    digest(path)  # Apply the same linked-input guard as other artifacts.
    root = ET.parse(path).getroot()
    for node in root.iter():
        if node.tag.rsplit('}', 1)[-1] in {'lastUpdated', 'updated'}:
            node.text = ''
        elif node.text:
            node.text = node.text.strip()
        node.tail = None
    return hashlib.sha256(ET.tostring(root)).hexdigest()


def facts(base, java):
    paths = sorted([*(base / 'src/main/java').rglob('*.java'),
                    *(base / 'src/test/java').rglob('*.java')])
    if not paths:
        raise ValueError('no standard Java sources')
    for path in paths:
        if path.is_symlink():
            raise ValueError('linked Java source')
    with tempfile.NamedTemporaryFile(mode='w', suffix='.txt') as listing:
        listing.write('\n'.join(str(path) for path in paths))
        listing.flush()
        result = subprocess.run([str(java), '--source', '17',
                                 str(Path(__file__).with_name('JavaSourceFacts.java')), listing.name],
                                capture_output=True, text=True, timeout=60)
    if result.returncode:
        raise ValueError('Java source parsing requires a compatible JDK 17+; ' + result.stderr[-600:])
    parsed = {}
    for line in result.stdout.splitlines():
        encoded, shape, identifiers, bodies = line.split('\t')
        path = Path(base64.b64decode(encoded).decode()).relative_to(base).as_posix()
        prefix = 'src/main/java/' if path.startswith('src/main/java/') else 'src/test/java/'
        parsed[path] = {'shape': shape, 'names': identifiers.split(','),
                        'class': path[len(prefix):-5].replace('/', '.'),
                        'bodies': [{'hash': body.split(':')[0], 'writes': body.split(':')[1] == 'true'}
                                   for body in bodies.split(',') if body]}
    if len(parsed) != len(paths):
        raise ValueError('incomplete Java source inventory')
    return parsed


def state_writes_changed(before, after):
    if 'bodies' not in before or 'bodies' not in after or len(before['bodies']) != len(after['bodies']):
        return True
    # Without attribution, assignment targets may be shared even when unqualified.
    return any(left['hash'] != right['hash'] and (left['writes'] or right['writes'])
               for left, right in zip(before['bodies'], after['bodies']))


def bytecode(base):
    result = {}
    for root in ['classes', 'test-classes']:
        for path in (base / 'target' / root).rglob('*.class'):
            result[path.relative_to(base).as_posix()] = digest(path)
    return result


def owned_archive(base, jar):
    """Validate rebuilt classes separately from stable archive resources."""
    resources, seen = {}, set()
    try:
        with zipfile.ZipFile(jar) as archive:
            for item in archive.infolist():
                if item.is_dir():
                    continue
                path = Path(item.filename)
                if path.is_absolute() or '..' in path.parts or item.filename in seen:
                    raise ValueError('nonstandard project archive entries')
                seen.add(item.filename)
                sha = hashlib.sha256(archive.read(item)).hexdigest()
                if item.filename.endswith('.class'):
                    compiled = base / 'target/classes' / path
                    if not compiled.is_file() or digest(compiled) != sha:
                        raise ValueError('project archive differs from prepared class bytecode')
                else:
                    resources[item.filename] = sha
    except zipfile.BadZipFile as error:
        raise ValueError('invalid project archive') from error
    return resources


def maven_flag_tokens(base):
    values = [os.environ.get('MAVEN_OPTS', ''), os.environ.get('MAVEN_ARGS', '')]
    maven_config = base / '.mvn/maven.config'
    if maven_config.is_file():
        values.append(maven_config.read_text())
    for path in [base / '.makevn/config', base / '.makevn/profile.env']:
        if not path.is_file():
            continue
        for line in path.read_text().splitlines():
            if line.lstrip().startswith('#'):
                continue
            # Decode shell quoting/%q without sourcing repository-controlled files.
            for token in shlex.split(line):
                if token.startswith('#'):
                    break
                name, separator, value = token.partition('=')
                if separator and (name.endswith(('_CLI_FLAGS', '_PROP_FLAGS')) or
                                  name in {'MAVEN_ARGS', 'MAVEN_OPTS'}):
                    values.append(value)
    tokens = []
    for value in values:
        if '$' in value or '`' in value:
            raise ValueError('cannot statically decode dynamic Maven flag values')
        # MakeVN's read -ra does not interpret embedded quotes. Keep both views
        # because direct Maven environment/config values can also be shell-quoted.
        tokens.extend(value.split())
        tokens.extend(shlex.split(value))
    return tokens


def validate_layout(base):
    from changes_scope import declared_modules, parse
    if declared_modules(base, parse((base / 'pom.xml').read_text())) != set():
        raise ValueError('reactor consumer evidence is unavailable; complete owner suites retained')
    flags = maven_flag_tokens(base)
    if any('maven.repo.local' in flag or flag.startswith(('-s', '-gs', '--settings', '--global-settings'))
           for flag in flags):
        raise ValueError('custom Maven settings/repository evidence is unsupported')
    for name in ['generated-sources', 'generated-test-sources']:
        if any((base / 'target' / name).rglob('*.java')):
            raise ValueError('generated Java sources have no validated impact graph')


def report_inventory(base, stamp):
    tests = set()
    for plugin in ['surefire-reports', 'failsafe-reports']:
        for path in (base / 'target' / plugin).glob('TEST-*.xml'):
            if path.stat().st_mtime_ns < stamp.stat().st_mtime_ns:
                continue
            root = ET.parse(path).getroot()
            cases = list(root.iter('testcase'))
            if not cases or any(case.find('failure') is not None or case.find('error') is not None for case in cases):
                raise ValueError('baseline has empty or failed test reports')
            names = {case.get('classname', '').split('$')[0] for case in cases}
            for name in names:
                if not name or not any(case.get('classname', '').split('$')[0] == name and
                                       case.find('skipped') is None for case in cases):
                    raise ValueError('baseline has an entirely skipped test class')
                from selected_test_reports import is_integration
                if is_integration(base, name) != (plugin == 'failsafe-reports'):
                    raise ValueError('custom test plugin ownership is unsupported: ' + name)
                tests.add(name)
    if not tests:
        raise ValueError('no fresh complete-suite test inventory')
    return sorted(tests)


def begin(repo, base, java, stamp):
    directory = state(repo)
    # A failed capture must never leave an older map eligible for selection.
    save(directory / 'map.json', {'version': VERSION, 'status': 'pending'})
    validate_layout(base)
    source_facts = facts(base, java)
    tests = report_inventory(base, stamp)
    known = {value['class'] for key, value in source_facts.items() if key.startswith('src/test/java/')}
    if not set(tests).issubset(known):
        raise ValueError('test inventory has nonstandard/generated source ownership')
    compiled = bytecode(base)
    known = {value['class'] for value in source_facts.values()}
    for path in compiled:
        name = path.split('/', 2)[2][:-6].replace('/', '.').split('$')[0]
        if name not in known:
            raise ValueError('compiled class has no standard source owner: ' + name)
    value = {'version': VERSION, 'status': 'pending', 'base': str(base),
             'head': subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD']).decode().strip(),
             'inputs': inputs(repo, base), 'context': context(java), 'facts': source_facts,
             'bytecode': compiled, 'tests': tests, 'records': {}, 'jars': {}, 'owned_jars': {}}
    save(directory / 'capture.json', value)
    print('\n'.join(tests))


def record(repo, base, name, traces):
    path = state(repo) / 'capture.json'
    value = json.loads(path.read_text())
    if name not in value['tests'] or name in value['records']:
        raise ValueError('unexpected or duplicate test capture')
    loaded, sources = set(), set()
    for trace in traces.glob('*.log'):
        for line in trace.read_text(errors='replace').splitlines():
            match = re.search(r'\[class,load\]\s+(\S+)\s+source:\s+(.+)', line)
            if match:
                loaded.add(match[1].split('$')[0])
                sources.add(match[2])
    if name not in loaded:
        raise ValueError('missing test JVM class-loading trace: ' + name)
    for source in sources:
        if source.startswith('file:'):
            jar = Path(urllib.parse.unquote(urllib.parse.urlparse(source).path))
            if jar.suffix == '.jar' and jar.is_file():
                if jar.is_relative_to(base / 'target'):
                    resources = owned_archive(base, jar)
                    previous = value.setdefault('owned_jars', {}).get(str(jar), resources)
                    if resources != previous:
                        raise ValueError('project archive resources changed between test executions')
                    value['owned_jars'][str(jar)] = resources
                    continue
                if str(jar) in value['jars'] and value['jars'][str(jar)] != digest(jar):
                    raise ValueError('dependency changed between isolated test executions')
                value['jars'][str(jar)] = digest(jar)
                settings = jar.parent.parent / 'conf/settings.xml'
                if settings.is_file():
                    value['jars'][str(settings)] = digest(settings)
    known = {item['class'] for key, item in value['facts'].items() if key.startswith('src/main/java/')}
    value['records'][name] = sorted(loaded & known)
    if value['inputs'] != inputs(repo, base) or value['bytecode'] != bytecode(base):
        raise ValueError('source/config/bytecode changed during test capture')
    save(path, value)


def finish(repo, base, java):
    value = json.loads((state(repo) / 'capture.json').read_text())
    if set(value['records']) != set(value['tests']):
        raise ValueError('incomplete isolated test capture')
    if value['inputs'] != inputs(repo, base):
        raise ValueError('source/config changed during test capture')
    current_context = context(java)
    if value['context'] != current_context:
        raise ValueError('JDK/environment changed during test capture: ' +
                         ', '.join(changed_context(value['context'], current_context)))
    value['status'] = 'success'
    value['models'] = repository_models()
    value['seal'] = hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()
    save(state(repo) / 'map.json', value)


def changed_context(before, after):
    fields = [key for key in after if before.get(key) != after[key]]
    if fields == ['environment'] and isinstance(before['environment'], dict):
        previous, current = before['environment'], after['environment']
        return sorted(key for key in previous.keys() | current.keys() if previous.get(key) != current.get(key))
    return fields


def validate_bytecode(base, value, paths):
    current = bytecode(base)
    if set(current) != set(value['bytecode']):
        raise ValueError('compiled class inventory changed or was cleaned')
    prefixes = []
    for path in paths:
        if path.startswith('src/main/java/'):
            prefixes.append('target/classes/' + path[len('src/main/java/'):-5])
        elif path.startswith('src/test/java/'):
            prefixes.append('target/test-classes/' + path[len('src/test/java/'):-5])
    for path, sha in current.items():
        if sha != value['bytecode'][path] and not any(path == prefix + '.class' or
                                                     path.startswith(prefix + '$') for prefix in prefixes):
            raise ValueError('unclassified compiled bytecode changed: ' + path)
    for path, resources in value.get('owned_jars', {}).items():
        if owned_archive(base, Path(path)) != resources:
            raise ValueError('project archive resources changed')
    models = repository_models()
    previous = value.get('models', {})
    metadata = lambda items: {key for key in items if Path(key).name.startswith('maven-metadata')}
    if any(models.get(key) != sha for key, sha in previous.items()) or metadata(models) != metadata(previous):
        raise ValueError('cached Maven model inventory changed; recapture the baseline')


def narrow(repo, base, owner, paths, changed_tests):
    """Return None on unknown impact; never turn missing evidence into no tests."""
    try:
        validate_layout(base)
        if owner != '.':
            raise ValueError('cross-module consumer evidence is unavailable')
        map_path = state(repo) / 'map.json'
        if not map_path.is_file():
            raise ValueError('no isolated test-impact baseline; explicitly capture with --record-test-impact')
        value = json.loads(map_path.read_text())
        seal = value.pop('seal', '')
        if (value.get('version') != VERSION or value.get('status') != 'success' or
                seal != hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()):
            raise ValueError('incomplete or altered test evidence')
        java = Path(os.environ.get('MAKEVN_TEST_IMPACT_JAVA', 'java'))
        current_context = context(java)
        if value['context'] != current_context:
            raise ValueError('JDK or execution environment changed: ' +
                             ', '.join(changed_context(value['context'], current_context)))
        if value['base'] != str(base):
            raise ValueError('evidence belongs to another Maven checkout')
        if value['head'] != subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD']).decode().strip():
            raise ValueError('baseline revision changed')
        current = inputs(repo, base)
        modified = {key for key in value['inputs'].keys() | current.keys()
                    if value['inputs'].get(key) != current.get(key)}
        allowed = {path for path in paths if '/src/main/java/' in '/' + path or '/src/test/java/' in '/' + path}
        from changes_scope import non_verification_path
        if any(path and path not in allowed and not non_verification_path(path) for path in paths):
            raise ValueError('POM/resource/build impact requires the complete owner suite')
        if modified - allowed:
            raise ValueError('configuration, dependencies, resources or unclassified sources changed')
        if not allowed or any(not (repo / path).is_file() for path in allowed):
            raise ValueError('new/deleted/unknown production input')
        parsed = facts(base, java)
        if set(parsed) != set(value['facts']):
            raise ValueError('Java source inventory changed')
        changed = set()
        for path in allowed:
            relative = (repo / path).relative_to(base).as_posix()
            if relative not in parsed:
                raise ValueError('nonstandard Java source')
            if relative.startswith('src/test/java/') and parsed[relative]['class'] not in changed_tests:
                raise ValueError('changed test helper requires the complete owner suite')
            if relative.startswith('src/main/java/'):
                if parsed[relative]['shape'] != value['facts'][relative]['shape']:
                    raise ValueError('production declaration, import or initializer changed')
                if state_writes_changed(value['facts'][relative], parsed[relative]):
                    raise ValueError('changed method may write shared Java state; test effects cannot be bounded')
                names = set(value['facts'][relative]['names']) | set(parsed[relative]['names'])
                if (DYNAMIC | UNSAFE_CHANGE).intersection(names):
                    raise ValueError('changed production class has unresolved dynamic/global-state/I/O behavior')
                changed.add(parsed[relative]['class'])
        validate_bytecode(base, value, [(repo / path).relative_to(base).as_posix() for path in allowed])
        for path, sha in value['jars'].items():
            if digest(Path(path)) != sha:
                raise ValueError('resolved dependency JAR changed')
        # Any dynamic source is a potential consumer of the changed code. Include
        # its transitive callers and tests rather than assuming no reflective edge.
        impacted = changed | {item['class'] for item in parsed.values()
                              if DYNAMIC.intersection(item['names'])}
        while True:
            simple = {name.rsplit('.', 1)[-1] for name in impacted}
            expanded = impacted | {item['class'] for item in parsed.values()
                                    if simple.intersection(item['names'])}
            if expanded == impacted:
                break
            impacted = expanded
        selected = set(changed_tests)
        selected.update(name for name, loaded in value['records'].items()
                        if impacted.intersection(loaded) or name in impacted)
        if not selected or not any(changed.intersection(loaded) for loaded in value['records'].values()):
            raise ValueError('changed classes have no recorded test evidence')
        print('Test impact ' + owner + ': validated isolated JVM evidence; ' + str(len(selected)) +
              '/' + str(len(value['tests'])) + ' test classes selected; baseline ' + value['head'][:12], file=sys.stderr)
        return selected
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError, ET.ParseError) as error:
        print('Test impact ' + owner + ': entire module suite; ' + str(error), file=sys.stderr)
        return None


if __name__ == '__main__':
    try:
        command, repo, base, *args = sys.argv[1:]
        repo, base = Path(repo).resolve(), Path(base).resolve()
        if command == 'begin':
            begin(repo, base, Path(args[0]), Path(args[1]))
        elif command == 'record':
            record(repo, base, args[0], Path(args[1]))
        elif command == 'finish':
            finish(repo, base, Path(args[0]))
        elif command == 'validate-prepared':
            value = json.loads((state(repo) / 'map.json').read_text())
            paths = [(repo / path).relative_to(base).as_posix() for path in sys.stdin.read().splitlines() if path]
            validate_bytecode(base, value, paths)
        else:
            raise ValueError('unknown test impact operation')
    except (OSError, ValueError, KeyError, ET.ParseError, subprocess.SubprocessError) as error:
        prefix = 'Prepared test impact is incompatible; preview again: ' if command == 'validate-prepared' else 'Cannot capture test impact: '
        print(prefix + str(error), file=sys.stderr)
        sys.exit(1)
