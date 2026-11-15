"""Bounded, read-only presentation of progressive test-impact facts."""
from collections import defaultdict, deque

import reactor_test_impact as reactor


def describe(value, index, focus=None, observation_status='none', depth=3, limit=10, show_all=False):
    if depth < 1 or limit < 1:
        raise ValueError('depth and limit must be positive integers')
    facts = value['facts']
    nodes = {item['class']: {'id': item['class'], 'module': item.get('owner', '.'),
                             'kind': ('test' if item['class'] in index['tests'] else 'helper') if reactor.is_source(source, 'test') else 'production'}
             for source, item in facts.items()}
    edges, observed = index['edges'], index['observed']
    modules = defaultdict(lambda: {'production': 0, 'tests': 0, 'static': 0, 'observed': 0})
    for node in nodes.values():
        if node['kind'] != 'helper':
            modules[node['module']]['tests' if node['kind'] == 'test' else 'production'] += 1
    for source, count in index['static_counts'].items():
        modules[nodes[source]['module']]['static'] += count
    for source, count in index['observed_counts'].items():
        if source in nodes:
            modules[nodes[source]['module']]['observed'] += count
    result = {'modules': dict(sorted(modules.items())), 'observation_status': observation_status,
              'depth': depth, 'limit': limit, 'show_all': show_all, 'nodes': [], 'edges': [], 'truncated': False, 'omitted': 0,
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
            if (depths[source] >= depth or (not show_all and (len(displayed) >= max(300, limit * 30) or
                    (target not in depths and len(depths) >= max(100, limit * 10))))):
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
            if (depths[source] >= depth or (not show_all and (len(displayed) >= max(300, limit * 30) or
                    (target not in depths and len(depths) >= max(100, limit * 10))))):
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
    lines = ['Test impact graph (conservative; observations: ' + ('none' if graph['observation_status'] == 'compatible' and not any(counts['observed'] for counts in graph['modules'].values()) else graph['observation_status']) + ')']
    for module, counts in graph['modules'].items():
        lines.append(f"{module}: {counts['production']} production, {counts['tests']} test, "
                     f"{counts['static']} static, {counts['observed']} observed relations")
    if 'focus' in graph:
        lines.append('Focus: ' + graph['focus'])
        nodes = {node['id']: node for node in graph['nodes']}
        labels = defaultdict(list)
        for name in nodes:
            labels[name.rsplit('.', 1)[-1]].append(name)
        direct, indirect = {}, {}
        for edge in graph['edges']:
            if edge['target'] == edge['source'] or edge['target'] == graph['focus']:
                continue
            target = edge['target']
            collection = direct if edge['source'] == graph['focus'] else indirect
            collection.setdefault(target, []).append(edge)
        transitive_count = len(set(indirect) - set(direct))
        for name, evidence in indirect.items():
            direct.setdefault(name, []).extend(evidence)
        lines.append(f"Relationships within {graph['depth']} hops (shown graph scope):")
        for kind, title in [('test', 'Tests'), ('production', 'Production classes'), ('helper', 'Helpers and benchmarks')]:
            names = sorted(name for name in direct if nodes[name]['kind'] == kind)
            lines.append(f'  {title}: {len(names)}')
            shown = len(names) if graph['show_all'] else graph['limit']
            for name in names[:shown]:
                short = name.rsplit('.', 1)[-1]
                label = short if len(labels[short]) == 1 else name
                evidence = direct[name]
                flags = []
                if any(edge['observed'] for edge in evidence):
                    flags.append('observed')
                if any(edge['ambiguous'] for edge in evidence):
                    flags.append('ambiguous')
                if any(edge['conservative_reverse'] for edge in evidence):
                    flags.append('conservative')
                suffix = ' [' + ', '.join(flags) + ']' if flags else ''
                lines.append('    ' + label + suffix)
            if len(names) > shown:
                lines.append(f'    … {len(names) - shown} more in displayed scope')
        lines.append('Additional transitive nodes in displayed scope: ' + str(transitive_count))
        if graph['truncated']:
            lines.append('Partial graph: omitted relations: ' + str(graph['omitted']))
        lines.append('Relationships are conservative; use verify-changes-preview for test selection.')
    lines.append('Conservative seeds: ' + str(graph['conservative_seed_count']) +
                 '; ambiguous identifiers: ' + str(graph['ambiguous_identifier_count']))
    return '\n'.join(lines)
