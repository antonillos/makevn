"""Compare the freshly recomputed execution plan with fresh test reports."""


def plans(text):
    result = {}
    for line in text.splitlines():
        owner, separator, names = line.partition('\t')
        if owner and separator:
            result[owner] = {'mode': 'suite' if names == '*' else 'classes',
                             'classes': [] if names == '*' else sorted(set(filter(None, names.split(','))))}
    return result


def compare(effective_text, candidate_text, executed, skipped):
    effective, candidates = plans(effective_text), plans(candidate_text)
    result = {}
    for owner in sorted(effective.keys() | executed.keys() | skipped.keys()):
        plan = effective.get(owner, {'mode': 'unplanned', 'classes': []})
        actual = set(executed.get(owner, []))
        candidate = candidates.get(owner)
        baseline = plan if plan['mode'] == 'classes' else candidate
        comparable = baseline is not None and baseline['mode'] == 'classes'
        expected = set(baseline['classes']) if comparable else set()
        reason = None
        if plan['mode'] == 'suite':
            if candidate is None:
                reason = 'upstream dependency suite included by reactor -am'
            elif candidate['mode'] == 'classes':
                reason = 'reactor verification expands class candidates to complete module suites'
            else:
                reason = 'planner retained a complete suite; see preview diagnostics for fallback details'
        result[owner] = dict(mode=plan['mode'], planned=plan['classes'], candidates=candidate,
                             executed=sorted(actual), skippedOnly=skipped.get(owner, []),
                             classComparisonAvailable=comparable,
                             notExecuted=sorted(expected - actual),
                             additional=sorted(actual - expected) if comparable or plan['mode'] == 'unplanned' else [],
                             expansionReason=reason)
    return result
