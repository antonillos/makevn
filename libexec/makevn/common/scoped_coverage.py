"""Fresh focused-run evidence shared by coverage-changes and crap-changes."""
import csv
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zipfile


VERSION = '0.8.14'


def comparison_commit(repo, reference):
    return subprocess.check_output(['git', '-C', str(repo), 'merge-base',
                                    reference.removesuffix('...HEAD'), 'HEAD']).decode().strip()


def evidence_comparison_commit(repo, manifest):
    return manifest.get('comparison_base') or comparison_commit(repo, manifest['comparison_head'])


def fingerprint(repo, base=None, inputs=None):
    head = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'])
    git_root = Path(subprocess.check_output(['git', '-C', str(repo), 'rev-parse', '--show-toplevel']).decode().strip()).resolve()
    paths = set(subprocess.check_output(['git', '-C', str(git_root), 'ls-files', '-z', '--cached', '--others', '--exclude-standard']).split(b'\0'))
    digest = hashlib.sha256(head)
    if inputs is not None:
        inputs["<HEAD>"] = hashlib.sha256(head).hexdigest()
    resource_paths = []
    if base is not None:
        resource_paths.append((base.resolve() / 'src/test/resources').relative_to(git_root))
    for prefix in resource_paths:
        if prefix.is_absolute() or '..' in prefix.parts or not any(prefix.parts[i:i+3] == ('src', 'test', 'resources') for i in range(len(prefix.parts) - 2)):
            raise ValueError('Invalid shared-resource path')
        resource = git_root / prefix
        if resource.resolve() != resource:
            raise ValueError('Refusing linked shared-resource prefix: ' + str(resource))
        # Shared inputs can include Git-ignored runtime fixtures too.
        for path in [resource, *resource.rglob('*')]:
            if path.is_symlink():
                raise ValueError('Refusing linked shared-resource input: ' + str(path))
            if path.is_file():
                paths.add(os.fsencode(path.relative_to(git_root)))
    for name in sorted(filter(None, paths)):
        path = git_root / os.fsdecode(name)
        if any(part in {'.makevn', 'target'} for part in path.relative_to(git_root).parts):
            continue
        if path.suffix not in {'.java', '.xml', '.yml', '.yaml', '.properties', '.avsc'} and not any(path.relative_to(git_root).is_relative_to(prefix) for prefix in resource_paths):
            continue
        digest.update(name)
        value = path.read_bytes() if path.is_file() else b'<deleted>'
        digest.update(value)
        if inputs is not None:
            inputs[os.fsdecode(name)] = hashlib.sha256(value).hexdigest()
    for name in ['config', 'profile.env']:
        path = repo / '.makevn' / name
        value = path.read_bytes() if path.is_file() else b''
        digest.update(value)
        if inputs is not None:
            inputs[str(path.resolve().relative_to(git_root))] = hashlib.sha256(value).hexdigest()
    return digest.hexdigest()


def data_files(base, owners):
    for owner in owners:
        target = base / owner / 'target'
        if target.is_symlink():
            raise ValueError('Refusing linked coverage target: ' + str(target))
        for path in sorted(target.rglob('*')):
            if path.is_file() and path.suffix in {'.exec', '.coverage'}:
                yield path


def prepare(repo, state, base, owners, sources, reference="HEAD"):
    comparison = reference.removesuffix("...HEAD")
    comparison_head = subprocess.check_output(["git", "-C", str(repo), "rev-parse", comparison]).decode().strip()
    # Pending replaces successful evidence before any Maven execution.
    state.mkdir(parents=True, exist_ok=True)
    inputs = {}
    manifest = {'status': 'pending', 'fingerprint': fingerprint(repo, base, inputs), 'inputs': inputs, 'base': str(base),
                'owners': owners, 'sources': sources, 'comparison': comparison, 'comparison_head': comparison_head,
                'comparison_base': comparison_commit(repo, reference)}
    (state / 'run.json').write_text(json.dumps(manifest))
    for evidence in state.glob('evidence-*'):
        if evidence.is_dir() and not evidence.is_symlink():
            shutil.rmtree(evidence)
    for path in data_files(base, owners):
        if path.is_symlink():
            raise ValueError('Refusing linked execution data: ' + str(path))
        backup = path.with_name(path.name + '.before-focused')
        if backup.exists() and not backup.is_file():
            raise ValueError('Invalid execution data backup: ' + str(backup))
        path.replace(backup)


def changed_inputs(manifest, current):
    previous = manifest.get('inputs', {})
    return sorted(name for name in previous.keys() | current.keys()
                  if previous.get(name) != current.get(name))


def drift_error(paths):
    names = ', '.join(paths[:20])
    suffix = ' (and more)' if len(paths) > 20 else ''
    return ValueError('Sources/config changed during focused verification; build generation or external edits may have changed inputs; rerun verify-changes. Changed inputs: ' + names + suffix)


def checkpoint(repo, state, plan):
    """Freeze prepared fixtures before tests, only with complete reactor suites."""
    manifest = json.loads((state / 'run.json').read_text())
    if manifest['status'] != 'pending' or manifest.get('checkpoint'):
        raise ValueError('Invalid focused preparation checkpoint')
    base = Path(manifest['base']).resolve()
    inputs = {}
    digest = fingerprint(repo, base, inputs)
    changed = changed_inputs(manifest, inputs)
    if digest != manifest['fingerprint']:
        git_root = Path(subprocess.check_output(['git', '-C', str(repo), 'rev-parse', '--show-toplevel']).decode().strip()).resolve()
        prefix = base / 'src/test/resources'
        if not changed or any(not (git_root / name).is_relative_to(prefix) for name in changed):
            raise drift_error(changed)
        # Import only when drift requires proving that all shared-input suites run.
        from changes_scope import parse, declared_modules
        from reactor_impact import automatic_resource_rules
        modules = declared_modules(base, parse((base / 'pom.xml').read_text()))
        rules = automatic_resource_rules(repo, base, modules, parse)
        full = {line.split('\t')[0] for line in plan.splitlines()
                if line.split('\t')[1:] == ['*']}
        if not rules:
            raise drift_error(changed)
        missing = rules[0][1] - (full & set(manifest['owners']))
        if missing:
            raise ValueError('Prepared shared fixtures changed, but the current plan does not run all consumer suites. '
                             'Inspect the changed files, then run verify-changes-preview again with these files present '
                             'and review its scope before retrying verification. Missing complete suites: ' +
                             ', '.join(sorted(missing)) + '. Changed inputs: ' + ', '.join(changed))
        print('Prepared shared fixtures changed; all consumer Maven suites will verify these inputs: ' + ', '.join(changed[:20]))
    # Preparation must not contribute execution data to test evidence.
    for path in data_files(base, manifest['owners']):
        if path.is_symlink():
            raise ValueError('Refusing linked execution data: ' + str(path))
        path.replace(path.with_name(path.name + '.before-focused'))
    manifest.update(fingerprint=digest, inputs=inputs, checkpoint=True,
                    preparation_changes=changed)
    (state / 'run.json').write_text(json.dumps(manifest))


def finish(repo, state):
    manifest = json.loads((state / 'run.json').read_text())
    inputs = {}
    if manifest['fingerprint'] != fingerprint(repo, Path(manifest['base']), inputs):
        raise drift_error(changed_inputs(manifest, inputs))
    base = Path(manifest['base'])
    snapshot = Path(tempfile.mkdtemp(prefix='evidence-', dir=state))
    files = []
    for index, path in enumerate(data_files(base, manifest['owners'])):
        target = snapshot / ('data-' + str(index) + '.exec')
        shutil.copyfile(path, target)
        files.append(str(target))
    classes = snapshot / 'classes'
    classes.mkdir()
    expected = []
    missing = []
    class_owners = {}
    for source in manifest['sources']:
        path = repo / source
        if not path.is_file():
            continue
        source_path = path.relative_to(base).as_posix()
        if source_path.startswith('src/main/java/'):
            owner, relative = '.', source_path[len('src/main/java/'):]
        else:
            owner, relative = source_path.split('/src/main/java/', 1)
        stem = relative[:-5]
        compiled = base / owner / 'target/classes' / (stem + '.class')
        if stem in class_owners:
            raise ValueError("Duplicate changed class across modules: " + stem)
        class_owners[stem] = owner
        expected.append(stem)
        if not compiled.is_file():
            missing.append(str(compiled))
            continue
        for item in [compiled, *compiled.parent.glob(compiled.stem + '$*.class')]:
            target = classes / item.relative_to(base / owner / 'target/classes')
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(item, target)
    manifest.update(status='success', data=files, classes=str(classes), expected=expected,
                    report=str(snapshot / 'report'), missing=missing, class_owners=class_owners)
    manifest['hashes'] = {str(p): hashlib.sha256(p.read_bytes()).hexdigest()
                          for p in snapshot.rglob('*') if p.is_file()}
    (state / 'run.json').write_text(json.dumps(manifest))


def load(repo, state):
    manifest = json.loads((state / 'run.json').read_text())
    if manifest.get('legacy_html_cleanup'):
        raise ValueError('Focused HTML cleanup was interrupted; rerun makevn clean before using this evidence')
    if comparison_commit(repo, manifest['comparison']) != evidence_comparison_commit(repo, manifest):
        raise ValueError('Comparison base changed; rerun verify-changes')
    if manifest['status'] != 'success':
        raise ValueError('Focused coverage is incomplete: the last verification did not complete successfully '
                         '(failed, interrupted or still running). No valid focused evidence is available. '
                         'Inspect ' + str(repo / '.makevn/logs/verify-changes-*.log') +
                         ' and selected modules\' target/surefire-reports or target/failsafe-reports; '
                         'resolve the cause before rerunning verify-changes')
    inputs = {}
    if manifest['fingerprint'] != fingerprint(repo, Path(manifest['base']), inputs):
        paths = ', '.join(changed_inputs(manifest, inputs)[:20])
        raise ValueError('Focused coverage sources/config changed; rerun verify-changes. Changed inputs: ' + paths)
    if manifest.get('missing'):
        raise ValueError('Missing changed-class bytecode; rerun verify-changes: ' + ', '.join(manifest['missing']))
    if manifest['expected'] and not manifest['data']:
        raise ValueError('Changed production classes require fresh JaCoCo execution data, but none was captured. '
                         'Check that the effective Maven build binds a JaCoCo prepare-agent goal for the selected tests; '
                         'jacoco.skip=false alone does not activate an undeclared agent. '
                         'If the agent ran, check its execution-data path under the selected module target directory. '
                         'Then rerun verify-changes; existing global reports are not reused')
    for name, digest in manifest['hashes'].items():
        if hashlib.sha256(Path(name).read_bytes()).hexdigest() != digest:
            raise ValueError('Focused evidence changed; rerun verify-changes')
    return manifest


def archive_legacy_html(state):
    manifest_path = state / 'run.json'
    if manifest_path.is_symlink():
        raise ValueError('Refusing linked focused coverage manifest: ' + str(manifest_path))
    if not manifest_path.is_file():
        if any(state.glob('evidence-*/report/index.html')):
            raise ValueError('Legacy focused HTML exists without a manifest; preserve it and inspect the focused coverage state')
        return
    manifest = json.loads(manifest_path.read_text())
    if not manifest.get('report') or not manifest.get('report_hashes'):
        if any(state.glob('evidence-*/report/index.html')):
            raise ValueError('Legacy focused HTML has no recorded report hashes; preserve it and inspect the focused coverage state')
        return
    output = Path(manifest['report'])
    if output.is_symlink() or output.parent.is_symlink() or output.parent.parent.resolve() != state.resolve() or not output.parent.name.startswith('evidence-') or output.name != 'report':
        raise ValueError('Invalid focused coverage report location')
    if any(path.parent.resolve() != output.resolve() for path in state.glob('evidence-*/report/index.html')):
        raise ValueError('Other legacy focused HTML is not covered by the current manifest; preserve it and inspect the focused coverage state')
    archive = output / 'jacoco-html.zip'
    if archive.is_symlink():
        raise ValueError('Refusing linked focused HTML archive: ' + str(archive))
    pending = manifest.get('legacy_html_cleanup')
    if pending:
        if not archive.is_file() or hashlib.sha256(archive.read_bytes()).hexdigest() != manifest['report_hashes'].get(str(archive)):
            raise ValueError('Focused HTML archive changed during cleanup')
        entries = {Path(name): digest for name, digest in pending.items()}
    else:
        entries = {Path(name): digest for name, digest in manifest['report_hashes'].items()
                   if Path(name).name not in ('jacoco.xml', 'jacoco.csv', 'jacoco-html.zip')}
        if not entries:
            return
    for path, digest in entries.items():
        if not path.is_relative_to(output) or path.is_symlink() or path.resolve() != output.resolve() / path.relative_to(output):
            raise ValueError('Invalid legacy coverage report entry: ' + str(path))
        if path.exists() and hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise ValueError('Legacy coverage report changed: ' + str(path))
        if not pending and not path.is_file():
            raise ValueError('Legacy coverage report missing: ' + str(path))
    if not pending:
        if archive.exists():
            with zipfile.ZipFile(archive) as bundle:
                names = {path.relative_to(output).as_posix(): digest for path, digest in entries.items()}
                if len(bundle.namelist()) != len(names) or set(bundle.namelist()) != set(names) or any(hashlib.sha256(bundle.read(name)).hexdigest() != digest for name, digest in names.items()):
                    raise ValueError('Existing focused HTML archive does not match legacy report')
        else:
            with tempfile.NamedTemporaryFile(dir=output, prefix='.jacoco-html-', delete=False) as stream:
                temporary = Path(stream.name)
            try:
                with zipfile.ZipFile(temporary, 'w', zipfile.ZIP_DEFLATED) as bundle:
                    for path in sorted(entries):
                        bundle.write(path, path.relative_to(output))
                os.replace(temporary, archive)
            finally:
                temporary.unlink(missing_ok=True)
        manifest['report_hashes'] = {name: digest for name, digest in manifest['report_hashes'].items() if Path(name) not in entries}
        manifest['report_hashes'][str(archive)] = hashlib.sha256(archive.read_bytes()).hexdigest()
        manifest['legacy_html_cleanup'] = {str(path): digest for path, digest in entries.items()}
        save_manifest(manifest_path, manifest)
    for path, digest in entries.items():
        if path.exists() and (path.is_symlink() or hashlib.sha256(path.read_bytes()).hexdigest() != digest):
            raise ValueError('Legacy coverage report changed during cleanup: ' + str(path))
        path.unlink(missing_ok=True)
    for directory in sorted((p for p in output.rglob('*') if p.is_dir()), key=lambda p: len(p.parts), reverse=True):
        if not directory.is_symlink():
            try:
                directory.rmdir()
            except OSError:
                pass
    manifest.pop('legacy_html_cleanup', None)
    save_manifest(manifest_path, manifest)
    print('Archived existing focused JaCoCo HTML: ' + str(archive))


def save_manifest(path, manifest):
    with tempfile.NamedTemporaryFile(mode='w', dir=path.parent, delete=False) as stream:
        try:
            json.dump(manifest, stream)
            temporary = Path(stream.name)
        except BaseException:
            Path(stream.name).unlink(missing_ok=True)
            raise
    try:
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def report(repo, state, maven, java, reference=""):
    if reference:
        requested = comparison_commit(repo, reference)
        manifest = load(repo, state)
        if requested != evidence_comparison_commit(repo, manifest):
            raise ValueError("Requested base differs from focused verification; rerun matching verification")
    manifest = load(repo, state)
    if not manifest['expected']:
        print('not-applicable')
        return
    output = Path(manifest['report'])
    output.mkdir(exist_ok=True)
    if manifest.get('report_hashes') and all(Path(p).is_file() and hashlib.sha256(Path(p).read_bytes()).hexdigest() == digest for p, digest in manifest['report_hashes'].items()):
        print(output)
        return
    jar = state / ('org.jacoco.cli-' + VERSION + '-nodeps.jar')
    if not jar.is_file():
        with tempfile.TemporaryDirectory(prefix='makevn-coverage-tool-') as directory:
            pom = Path(directory) / 'pom.xml'
            pom.write_text('<project><modelVersion>4.0.0</modelVersion><groupId>makevn</groupId><artifactId>coverage-tool</artifactId><version>1</version></project>')
            environment = dict(os.environ, JAVA_HOME=str(Path(java).parent.parent))
            subprocess.run([maven, '-f', str(pom), 'org.apache.maven.plugins:maven-dependency-plugin:3.8.1:copy',
                            '-Dartifact=org.jacoco:org.jacoco.cli:' + VERSION + ':jar:nodeps',
                            '-DoutputDirectory=' + str(state)], check=True, cwd=repo, env=environment)
    with tempfile.TemporaryDirectory(prefix='makevn-jacoco-html-') as directory:
        html = Path(directory)
        command = [java, '-jar', str(jar), 'report', *manifest['data'], '--classfiles', manifest['classes'],
                   '--name', 'makevn focused changes (not global coverage)', '--xml', str(output / 'jacoco.xml'),
                   '--csv', str(output / 'jacoco.csv'), '--html', str(html)]
        for owner in manifest['owners']:
            command += ['--sourcefiles', str(Path(manifest['base']) / owner / 'src/main/java')]
        result = subprocess.run(command, check=True, capture_output=True, text=True)
        with zipfile.ZipFile(output / 'jacoco-html.zip', 'w', zipfile.ZIP_DEFLATED) as bundle:
            for item in sorted(html.rglob('*')):
                if item.is_file():
                    bundle.write(item, item.relative_to(html))
    if 'does not match' in result.stdout + result.stderr:
        raise ValueError('JaCoCo bytecode/data mismatch; rerun verify-changes')
    root = ET.parse(output / 'jacoco.xml').getroot()
    actual = {node.get('name') for node in root.findall('.//class')}
    if not set(manifest['expected']).issubset(actual):
        raise ValueError('Changed classes missing from focused coverage report')
    csv_path = output / 'jacoco.csv'
    with csv_path.open(newline='') as stream:
        reader = csv.DictReader(stream)
        rows, fields = list(reader), reader.fieldnames
    for row in rows:
        name = (row['PACKAGE'] + '/' + row['CLASS']).lstrip('/').split('$', 1)[0]
        row['GROUP'] = manifest['class_owners'].get(name, 'focused changes')
    with csv_path.open('w', newline='') as stream:
        writer = csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)
    load(repo, state)  # Source/config cannot change during report generation either.
    manifest['report_hashes'] = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in output.rglob('*') if p.is_file()}
    (state / 'run.json').write_text(json.dumps(manifest))
    print(output)


def main():
    action, repo, state, *args = sys.argv[1:]
    repo, state = Path(repo).resolve(), Path(state).resolve()
    if action == 'archive-html' and not state.is_relative_to(repo):
        raise ValueError('Focused coverage state is outside the repository')
    if action == 'prepare':
        prepare(repo, state, Path(args[0]).resolve(), args[1].split(','), list(filter(None, args[2].splitlines())), args[3])
    elif action == 'checkpoint':
        checkpoint(repo, state, args[0])
    elif action == 'finish':
        finish(repo, state)
    elif action == 'archive-html':
        archive_legacy_html(state)
    elif action == 'report':
        report(repo, state, *args)
    elif action == 'applicability':
        manifest = load(repo, state)
        if args and args[0]:
            requested = comparison_commit(repo, args[0])
            if requested != evidence_comparison_commit(repo, manifest):
                raise ValueError('Requested base differs from focused verification; rerun matching verification')
        print('applicable' if manifest['expected'] else 'not-applicable')
    else:
        raise ValueError('Unknown focused coverage action: ' + action)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError, ET.ParseError, zipfile.BadZipFile) as error:
        print('Error: focused coverage: ' + str(error), file=sys.stderr)
        sys.exit(1)
