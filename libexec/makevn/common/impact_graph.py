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
            if depths[source] >= depth:
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
            if depths[source] >= depth:
                omitted += 1
                continue
            repeat = target in depths
            if not repeat:
                depths[target] = depths[source] + 1
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
    visible_edges = [edge for edge in displayed
                     if edge['source'] in visible and edge['target'] in visible]
    evidence = defaultdict(set)
    for edge in displayed:
        for flag in ('observed', 'ambiguous', 'conservative_reverse'):
            if edge[flag]:
                evidence[edge['target']].add(flag)
    result.update(focus=root,
                  nodes=[nodes[name] | {'depth': distance, 'evidence': sorted(evidence[name])}
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
        layers = list(graph['layers'].items())
        for layer_index, (distance, counts) in enumerate(layers):
            last_layer = layer_index == len(layers) - 1
            lines.append(('└── ' if last_layer else '├── ') + f'Hop {distance}:')
            layer_prefix = '    ' if last_layer else '│   '
            categories = [(kind, title) for kind, title in [
                ('test', 'Tests'), ('production', 'Production classes'),
                ('helper', 'Helpers and benchmarks')] if counts[kind]]
            for category_index, (kind, title) in enumerate(categories):
                last_category = category_index == len(categories) - 1
                lines.append(layer_prefix + ('└── ' if last_category else '├── ') + f'{title}: {counts[kind]}')
                item_prefix = layer_prefix + ('    ' if last_category else '│   ')
                names = sorted(name for name, node in nodes.items()
                               if node['depth'] == int(distance) and node['kind'] == kind)
                entries = []
                for name in names:
                    short = name.rsplit('.', 1)[-1]
                    label = short if len(labels[short]) == 1 else name
                    flags = [flag for flag in ('observed', 'ambiguous')
                             if flag in nodes[name]['evidence']]
                    if 'conservative_reverse' in nodes[name]['evidence']:
                        flags.append('conservative')
                    suffix = ' [' + ', '.join(flags) + ']' if flags else ''
                    entries.append(label + suffix)
                if counts[kind] > len(names):
                    entries.append(f"… {counts[kind] - len(names)} more (use --limit or --all)")
                for entry_index, entry in enumerate(entries):
                    branch = '└── ' if entry_index == len(entries) - 1 else '├── '
                    lines.append(item_prefix + branch + entry)
        if graph['hidden_nodes']:
            lines.append('Hidden classes due to display limit: ' + str(graph['hidden_nodes']))
        if graph['depth_boundary_relations']:
            lines.append('Relations not expanded at depth boundary: ' + str(graph['depth_boundary_relations']))
        lines.append('Relationships are conservative; use verify-changes-preview for test selection.')
    lines.append('Conservative seeds: ' + str(graph['conservative_seed_count']) +
                 '; ambiguous identifiers: ' + str(graph['ambiguous_identifier_count']))
    return '\n'.join(lines)
