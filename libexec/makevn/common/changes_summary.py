"""Summarize only reports modified during the current changed-code run."""
import json
import hashlib
import tempfile
from pathlib import Path
import sys
import xml.etree.ElementTree as ET


def summarize(base, started, exit_code):
    modules = {}
    for path in sorted(base.rglob('TEST-*.xml')):
        if path.parent.name not in {'surefire-reports', 'failsafe-reports'} or path.stat().st_mtime < started:
            continue
        node = ET.parse(path).getroot()
        owner = path.parent.parent.parent.relative_to(base).as_posix()
        counts = modules.setdefault(owner, dict(tests=0, failures=0, errors=0, skipped=0))
        for key in counts:
            counts[key] += int(node.get(key, '0'))
    return dict(exitCode=exit_code, scope='focused', modules=modules,
                globalGates='not established by focused verification')


def summary_path(repo):
    return repo / '.makevn/reports/verify-changes/summary.json'


def run_identity(repo):
    state = json.loads((repo / '.makevn/focused-coverage/run.json').read_text())
    keys = ('fingerprint', 'classes', 'comparison_head', 'comparison_base', 'owners', 'sources')
    return hashlib.sha256(json.dumps({k: state.get(k) for k in keys}, sort_keys=True).encode()).hexdigest()


def save_summary(output, summary):
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode='w', dir=output.parent, delete=False) as stream:
        json.dump(summary, stream, indent=2)
        stream.write('\n')
        temporary = Path(stream.name)
    temporary.replace(output)


def update_stage(repo, command, exit_code):
    output = summary_path(repo)
    if not output.is_file() or not (repo / '.makevn/focused-coverage/run.json').is_file():
        return
    summary = json.loads(output.read_text())
    if summary.get('runId') != run_identity(repo):
        return  # Never attach a command to another verification's summary.
    stage = 'coverage' if command == 'coverage-changes' else 'crap'
    result = dict(status='passed' if exit_code == 0 else 'failed', exitCode=exit_code)
    if exit_code == 0:
        from scoped_coverage import load
        manifest = load(repo, repo / '.makevn/focused-coverage')
        if not manifest['expected']:
            result['status'] = 'not_applicable'
            result['reason'] = 'no changed production classes'
        elif stage == 'coverage':
            report = Path(manifest['report']) / 'jacoco.xml'
            result['report'] = str(report)
            result['counters'] = {c.get('type'): dict(covered=int(c.get('covered', '0')),
                                                   missed=int(c.get('missed', '0')))
                                  for c in ET.parse(report).getroot().findall('counter')}
        else:
            report = repo / '.makevn/reports/crap-changes/report.json'
            payload = json.loads(report.read_text())
            result.update(report=str(report), methods=payload['diagnostics']['java_methods'],
                          warnings=payload['gate']['warnings'], gate=payload['gate']['status'])
    summary[stage] = result
    if stage == 'coverage':
        summary['crap'] = dict(status='not_run', reason='awaiting crap-changes' if exit_code == 0 else 'coverage did not pass')
    save_summary(output, summary)
    print('Changed-code ' + stage + ': ' + result['status'] + '; summary: ' + str(output))


def main(args):
    if args[0] == 'update':
        _, repo, command, code = args
        update_stage(Path(repo), command, int(code))
        return
    repo, base, stamp, code = args
    output = summary_path(Path(repo))
    summary = summarize(Path(base), Path(stamp).stat().st_mtime, int(code))
    try:
        run_id = run_identity(Path(repo))
    except FileNotFoundError:
        if code == '0':
            raise
        run_id = None
    summary.update(runId=run_id,
                   verification=dict(status='passed' if code == '0' else 'failed', exitCode=int(code)),
                   coverage=dict(status='not_run', reason='awaiting coverage-changes' if code == '0' else 'verification did not pass'),
                   crap=dict(status='not_run', reason='awaiting crap-changes' if code == '0' else 'verification did not pass'))
    save_summary(output, summary)
    totals = {key: sum(m[key] for m in summary['modules'].values()) for key in ('tests', 'failures', 'errors', 'skipped')}
    print('Changed-code verification: exit ' + code + '; ' + ', '.join(f'{key}={value}' for key, value in totals.items()))
    print('Summary: ' + str(output))
    if code != '0':
        print('If tests require reactor-local artifacts, use makevn verify to preserve the complete reactor; focused owner verification resolves installed dependencies.')


if __name__ == '__main__':
    main(sys.argv[1:])
