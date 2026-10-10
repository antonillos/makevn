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


VERSION = '0.8.14'


def fingerprint(repo):
    head = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'])
    paths = subprocess.check_output(['git', '-C', str(repo), 'ls-files', '-z', '--cached', '--others', '--exclude-standard']).split(b'\0')
    digest = hashlib.sha256(head)
    for name in sorted(filter(None, paths)):
        path = repo / os.fsdecode(name)
        if any(part in {'.makevn', 'target'} for part in path.relative_to(repo).parts) or path.suffix not in {'.java', '.xml', '.yml', '.yaml', '.properties'}:
            continue
        digest.update(name)
        digest.update(path.read_bytes() if path.is_file() else b'<deleted>')
    for name in ['config', 'profile.env']:
        path = repo / '.makevn' / name
        digest.update(path.read_bytes() if path.is_file() else b'')
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
    manifest = {'status': 'pending', 'fingerprint': fingerprint(repo), 'base': str(base),
                'owners': owners, 'sources': sources, 'comparison': comparison, 'comparison_head': comparison_head}
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


def finish(repo, state):
    manifest = json.loads((state / 'run.json').read_text())
    if manifest['fingerprint'] != fingerprint(repo):
        raise ValueError('Sources/config changed during focused verification; rerun verify-changes')
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
        owner, relative = path.relative_to(base).as_posix().split('/src/main/java/', 1)
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
    comparison_head = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', manifest['comparison']]).decode().strip()
    if comparison_head != manifest['comparison_head']:
        raise ValueError('Comparison base changed; rerun verify-changes')
    if manifest['status'] != 'success' or manifest['fingerprint'] != fingerprint(repo):
        raise ValueError('Focused coverage is incomplete or sources/config changed; rerun verify-changes')
    if manifest.get('missing'):
        raise ValueError('Missing changed-class bytecode; rerun verify-changes: ' + ', '.join(manifest['missing']))
    if not manifest['data'] or not manifest['expected']:
        raise ValueError('No fresh JaCoCo data or changed production classes. Enable coverage agents and rerun verify-changes; use full coverage for test/POM-only changes')
    for name, digest in manifest['hashes'].items():
        if hashlib.sha256(Path(name).read_bytes()).hexdigest() != digest:
            raise ValueError('Focused evidence changed; rerun verify-changes')
    return manifest


def report(repo, state, maven, java, reference=""):
    if reference:
        requested = subprocess.check_output(["git", "-C", str(repo), "rev-parse", reference.removesuffix("...HEAD")]).decode().strip()
        if requested != load(repo, state)["comparison_head"]:
            raise ValueError("Requested base differs from focused verification; rerun matching verification")
    manifest = load(repo, state)
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
                            '-DoutputDirectory=' + str(state)], check=True, cwd=directory, env=environment)
    command = [java, '-jar', str(jar), 'report', *manifest['data'], '--classfiles', manifest['classes'],
               '--name', 'makevn focused changes (not global coverage)', '--xml', str(output / 'jacoco.xml'),
               '--csv', str(output / 'jacoco.csv'), '--html', str(output)]
    for owner in manifest['owners']:
        command += ['--sourcefiles', str(Path(manifest['base']) / owner / 'src/main/java')]
    result = subprocess.run(command, check=True, capture_output=True, text=True)
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
    if action == 'prepare':
        prepare(repo, state, Path(args[0]).resolve(), args[1].split(','), list(filter(None, args[2].splitlines())), args[3])
    elif action == 'finish':
        finish(repo, state)
    elif action == 'report':
        report(repo, state, *args)
    else:
        raise ValueError('Unknown focused coverage action: ' + action)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError, ET.ParseError) as error:
        print('Error: focused coverage: ' + str(error), file=sys.stderr)
        sys.exit(1)
