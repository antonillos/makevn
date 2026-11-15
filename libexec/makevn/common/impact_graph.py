"""Bounded, read-only presentation of progressive test-impact facts."""
from collections import defaultdict, deque

import reactor_test_impact as reactor


def describe(value, index, focus=None, observation_status='none'):
    facts = value['facts']
    nodes = {item['class']: {'id': item['class'], 'module': item.get('owner', '.'),
                             'kind': 'test' if reactor.is_source(source, 'test') else 'production'}
             for source, item in facts.items()}
    edges, observed = index['edges'], index['observed']
    modules = defaultdict(lambda: {'production': 0, 'tests': 0, 'static': 0, 'observed': 0})
    for node in nodes.values():
        modules[node['module']]['tests' if node['kind'] == 'test' else 'production'] += 1
    for source, targets in edges.items():
        for target in targets:
            modules[nodes[source]['module']]['static'] += 1
    for source, targets in observed.items():
        if source in nodes:
            modules[nodes[source]['module']]['observed'] += len(targets)
    result = {'modules': dict(sorted(modules.items())), 'observation_status': observation_status,
              'nodes': [], 'edges': [], 'truncated': False, 'omitted': 0,
              'conservative_seed_count': len(index['seeds']),
              'ambiguous_identifier_count': len(index['ambiguous'])}
    if focus is None:
        return result
    matches = sorted(name for name in nodes if name == focus or name.split('::')[-1] == focus)
    if len(matches) != 1:
        raise ValueError(('Ambiguous class; choose: ' + ', '.join(matches)) if matches
                         else 'Class not found: ' + focus)
    root = matches[0]
    queue, depths = deque([root]), {root: 0}
    displayed, omitted = [], 0
    while queue:
        source = queue.popleft()
        for target in sorted(edges.get(source, set())):
            if target not in nodes:
                continue
            if (depths[source] >= 3 or len(displayed) >= 300 or
                    (target not in depths and len(depths) >= 100)):
                omitted += 1
                continue
            repeat = target in depths
            if not repeat:
                depths[target] = depths[source] + 1
                queue.append(target)
            displayed.append({'source': source, 'target': target,
                              'static': target in edges.get(source, ()),
                              'observed': target in observed.get(source, ()),
                              'ambiguous': (source, target) in index['ambiguous_edges'],
                              'conservative_reverse': (source, target) in index['conservative_edges'],
                              'repeated': repeat})
    for source in list(depths):
        for target in sorted(observed.get(source, set()) - edges.get(source, set())):
            if target not in nodes:
                continue
            if (depths[source] >= 3 or len(displayed) >= 300 or
                    (target not in depths and len(depths) >= 100)):
                omitted += 1
                continue
            repeat = target in depths
            if not repeat:
                depths[target] = depths[source] + 1
            displayed.append({'source': source, 'target': target, 'static': False,
                              'observed': True, 'ambiguous': False,
                              'conservative_reverse': False, 'repeated': repeat})
    result.update(focus=root, nodes=[nodes[name] | {'depth': depth} for name, depth in depths.items()],
                  edges=displayed, truncated=bool(omitted), omitted=omitted)
    remaining = {name for name in depths if nodes[name]['kind'] == 'production'}
    groups = []
    while remaining:
        start = min(remaining)
        remaining.remove(start)
        group, pending = {start}, [start]
        while pending:
            for neighbor in edges.get(pending.pop(), set()) & remaining:
                remaining.remove(neighbor)
                group.add(neighbor)
                pending.append(neighbor)
        if len(group) > 1:
            groups.append(sorted(group))
    result['production_groups'] = groups
    return result


def render(graph):
    lines = ['Test impact graph (conservative; observations: ' + graph['observation_status'] + ')']
    for module, counts in graph['modules'].items():
        lines.append(f"{module}: {counts['production']} production, {counts['tests']} test, "
                     f"{counts['static']} static, {counts['observed']} observed relations")
    if 'focus' in graph:
        lines.append('Focus: ' + graph['focus'])
        for group in graph['production_groups']:
            lines.append('Connected production group: ' + ', '.join(group))
        depths = {node['id']: node['depth'] for node in graph['nodes']}
        for edge in graph['edges']:
            kinds = ' + '.join(kind for kind in ('static', 'observed') if edge[kind])
            if edge['ambiguous']:
                kinds += ', ambiguous'
            if edge['conservative_reverse']:
                kinds += ', conservative reverse'
            suffix = ' (cycle or repeated)' if edge['repeated'] else ''
            lines.append('  ' * (depths[edge['source']] + 1) + edge['source'] + ' -> ' +
                         edge['target'] + ' [' + kinds + ']' + suffix)
        if graph['truncated']:
            lines.append('Omitted relations: ' + str(graph['omitted']))
    lines.append('Conservative seeds: ' + str(graph['conservative_seed_count']) +
                 '; ambiguous identifiers: ' + str(graph['ambiguous_identifier_count']))
    return '\n'.join(lines)
