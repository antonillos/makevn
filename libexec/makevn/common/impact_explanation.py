"""Read-only reasons emitted by the effective changed-code planner."""
import os
import sys


def emit(subject, reasons):
    if os.environ.get('MAKEVN_CHANGES_EXPLAIN') != 'true':
        return
    line = 'Explain: ' + subject + ': ' + '; '.join(sorted(set(reasons)))
    detail = os.environ.get('MAKEVN_BACKEND_DETAIL_OUT')
    if detail:
        with open(detail, 'a') as stream:
            stream.write(line + '\n')
    else:
        print(line, file=sys.stderr)


def explain_tests(current, owner, selected, changed_tests, affected, skipped, observations):
    if os.environ.get('MAKEVN_CHANGES_EXPLAIN') != 'true':
        return
    from reactor_test_impact import identity
    for test in sorted(selected):
        qualified = identity(current, owner, test)
        reasons = []
        if qualified in changed_tests:
            reasons.append('changed test')
        if qualified in affected:
            reasons.append('conservative static reachability from changes or dynamic/framework seeds')
        if qualified in skipped:
            reasons.append('previously skipped test retained conservatively')
        if any(qualified in observations.get(name, ()) for name in affected):
            reasons.append('compatible runtime observation intersects affected classes')
        emit(owner + '::' + test, reasons or ['compatible isolated evidence or explicit test selection'])
