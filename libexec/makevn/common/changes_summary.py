"""Summarize only reports modified during the current changed-code run."""
import json
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
                coverage='not evaluated; run coverage-changes after successful verification',
                crap='not evaluated; run crap-changes after successful coverage',
                globalGates='not established by focused verification')


def main(args):
    repo, base, stamp, code = args
    output = Path(repo) / '.makevn/reports/verify-changes/summary.json'
    summary = summarize(Path(base), Path(stamp).stat().st_mtime, int(code))
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(summary, indent=2) + '\n')
    totals = {key: sum(m[key] for m in summary['modules'].values()) for key in ('tests', 'failures', 'errors', 'skipped')}
    print('Changed-code verification: exit ' + code + '; ' + ', '.join(f'{key}={value}' for key, value in totals.items()))
    print('Summary: ' + str(output))
    if code != '0':
        print('If tests require reactor-local artifacts, use makevn verify to preserve the complete reactor; focused owner verification resolves installed dependencies.')


if __name__ == '__main__':
    main(sys.argv[1:])
