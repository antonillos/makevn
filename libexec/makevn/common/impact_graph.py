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
    parents = {root: None}
    displayed, omitted = [], 0
    while queue:
        source = queue.popleft()
        for target in sorted(edges.get(source, set())):
            if target not in nodes:
                continue
            if depths[source] >= depth:
                omitted += 1
                continue
            repeat = target in depths
            if not repeat:
                depths[target] = depths[source] + 1
                parents[target] = source
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
            if depths[source] >= depth:
                omitted += 1
                continue
            repeat = target in depths
            if not repeat:
                depths[target] = depths[source] + 1
                parents[target] = source
            displayed.append({'source': source, 'target': target, 'static': False,
                              'observed': True, 'ambiguous': False,
                              'conservative_reverse': False, 'repeated': repeat})
    layers = defaultdict(lambda: {'test': 0, 'production': 0, 'helper': 0})
    buckets = defaultdict(list)
    for name, distance in depths.items():
        if name != root:
            layers[distance][nodes[name]['kind']] += 1
            buckets[(distance, nodes[name]['kind'])].append(name)
    visible = {root}
    for names in buckets.values():
        visible.update(sorted(names) if show_all else sorted(names)[:limit])
    for name in list(visible):
        ancestor = parents[name]
        while ancestor is not None and ancestor not in visible:
            visible.add(ancestor)
            ancestor = parents[ancestor]
    visible_edges = [edge for edge in displayed
                     if edge['source'] in visible and edge['target'] in visible]
    evidence = defaultdict(set)
    for edge in displayed:
        for flag in ('observed', 'ambiguous', 'conservative_reverse'):
            if edge[flag]:
                evidence[edge['target']].add(flag)
    result.update(focus=root,
                  nodes=[nodes[name] | {'depth': distance, 'parent': parents[name], 'evidence': sorted(evidence[name])}
                         for name, distance in depths.items() if name in visible],
                  edges=visible_edges, truncated=bool(omitted or len(visible) < len(depths)),
                  omitted=omitted + len(displayed) - len(visible_edges),
                  layers=dict(sorted(layers.items())), reached_nodes=len(depths),
                  hidden_nodes=len(depths) - len(visible), depth_boundary_relations=omitted)
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
        lines.append(f"Reachable classes within {graph['depth']} hops: {graph['reached_nodes'] - 1}")
        children = defaultdict(list)
        references = defaultdict(int)
        tree_edges = {}
        for node in nodes.values():
            if node['parent'] is not None:
                children[node['parent']].append(node['id'])
        for edge in graph['edges']:
            if nodes[edge['target']]['parent'] == edge['source']:
                tree_edges[edge['target']] = edge
            elif edge['target'] != edge['source']:
                references[edge['source']] += 1
        lines.append(graph['focus'] + ' [L0]')
        stack = []
        def schedule(parent, prefix):
            names = sorted(children[parent])
            for index in range(len(names) - 1, -1, -1):
                stack.append((names[index], prefix, index == len(names) - 1))
        schedule(graph['focus'], '')
        while stack:
            name, prefix, last = stack.pop()
            node = nodes[name]
            short = name.rsplit('.', 1)[-1]
            label = short if len(labels[short]) == 1 else name
            flags = [f"L{node['depth']}", node['kind']]
            edge = tree_edges[name]
            flags.extend(flag for flag in ('observed', 'ambiguous') if edge[flag])
            if edge['conservative_reverse']:
                flags.append('conservative')
            if references[name]:
                flags.append(f"{references[name]} cross-references")
            lines.append(prefix + ('└── ' if last else '├── ') + label + ' [' + ', '.join(flags) + ']')
            schedule(name, prefix + ('    ' if last else '│   '))
        if references[graph['focus']]:
            lines.append('Root cross-references: ' + str(references[graph['focus']]))
        if graph['hidden_nodes']:
            lines.append('Hidden classes due to display limit: ' + str(graph['hidden_nodes']))
        if graph['depth_boundary_relations']:
            lines.append('Relations not expanded at depth boundary: ' + str(graph['depth_boundary_relations']))
        lines.append('Relationships are conservative; use verify-changes-preview for test selection.')
    lines.append('Conservative seeds: ' + str(graph['conservative_seed_count']) +
                 '; ambiguous identifiers: ' + str(graph['ambiguous_identifier_count']))
    return '\n'.join(lines)
