"""Inspect test filters on an owner's literal local or cached parent chain."""
import os
from pathlib import Path
import re


def read(pom):
    from changes_scope import parse
    return parse(pom.read_text())


def coordinates(root):
    return tuple((root.findtext(key) or root.findtext('parent/' + key, '')).strip()
                 for key in ['groupId', 'artifactId', 'version'])


def cached_parent(expected):
    if not all(re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_.-]*', value) and '..' not in value for value in expected):
        raise ValueError('unresolved test-inventory parent coordinates')
    repository = Path.home() / '.m2/repository'
    settings = Path(os.environ.get('MAVEN_CONFIG', str(Path.home() / '.m2'))) / 'settings.xml'
    if settings.is_file():
        location = read(settings).findtext('localRepository')
        if location:
            location = location.replace('${user.home}', str(Path.home()))
            if '${' in location or not Path(location).is_absolute():
                raise ValueError('unresolved test-inventory local repository')
            repository = Path(location)
    group, artifact, version = expected
    return repository / group.replace('.', '/') / artifact / version / (artifact + '-' + version + '.pom')


def model_records(base, owner):
    pom = (base / owner / 'pom.xml').resolve()
    seen = set()
    local = True
    while True:
        if pom in seen or len(seen) >= 32:
            raise ValueError('cyclic or excessively deep test-inventory parent chain')
        seen.add(pom)
        root = read(pom)
        yield pom, root
        parent = root.find('parent')
        if parent is None:
            return
        expected = tuple(parent.findtext(key, '').strip() for key in ['groupId', 'artifactId', 'version'])
        relative = parent.findtext('relativePath', '../pom.xml').strip()
        candidate = (pom.parent / relative).resolve() if local and relative else None
        if candidate is not None and candidate.is_dir():
            candidate /= 'pom.xml'
        if candidate is not None and candidate.is_file() and coordinates(read(candidate)) == expected:
            pom = candidate
            continue
        pom = cached_parent(expected)
        local = False
        if not pom.is_file() or coordinates(read(pom)) != expected:
            raise ValueError('test-inventory parent is unavailable in the local cache: ' + str(pom) + ' (' + ':'.join(expected) + ')')


def models(base, owner):
    for _, root in model_records(base, owner):
        yield root


DEFAULT_INCLUDES = {
    'maven-surefire-plugin': {'**/Test*.java', '**/*Test.java', '**/*Tests.java', '**/*TestCase.java'},
    'maven-failsafe-plugin': {'**/IT*.java', '**/*IT.java', '**/*ITCase.java'},
}


def filter_context(pom, root, element):
    parents = {child: parent for parent in root.iter() for child in parent}
    ancestors, node = [], element
    while node is not root:
        ancestors.append(node)
        node = parents[node]
    labels = []
    for node in reversed(ancestors):
        label = node.tag
        if node.tag in {'profile', 'execution'}:
            label += '[' + node.findtext('id', '<unnamed>') + ']'
        if node.tag == 'plugin':
            label += '[' + node.findtext('artifactId', '<unknown>') + ']'
        labels.append(label)
    return str(pom) + ': ' + '/'.join(labels), ancestors


def unsupported(context, detail):
    raise ValueError('configured test inventory is unknown; complete owner suite required; ' + context + ': ' + detail)


def validate(base, owner='.'):
    rules, locations = {}, {}
    for depth, (pom, root) in enumerate(model_records(base, owner)):
        for plugin in root.findall('.//plugin'):
            artifact = plugin.findtext('artifactId')
            if artifact not in DEFAULT_INCLUDES:
                continue
            inheritance = plugin.findtext('inherited', 'true').strip()
            if depth and inheritance != 'true':
                context, _ = filter_context(pom, root, plugin)
                unsupported(context, 'parent plugin inherited=' + repr(inheritance) +
                            '; ancestor filter merging is not proven')
            for config in plugin.findall('.//configuration'):
                filters = [node for node in config if node.tag in {'includes', 'excludes', 'includesFile', 'excludesFile'}]
                if not filters:
                    continue
                context, ancestors = filter_context(pom, root, filters[0])
                if plugin.findtext('groupId', 'org.apache.maven.plugins') != 'org.apache.maven.plugins':
                    unsupported(context, 'nonstandard test plugin group')
                if any(node.tag == 'profile' for node in ancestors):
                    patterns = [value.strip() for value in filters[0].itertext() if value.strip()]
                    unsupported(context, 'profile activation is not proven; filter=' + repr(patterns))
                if any(node.tag == 'execution' for node in ancestors):
                    unsupported(context, 'execution binding and configuration merging are not proven')
                if any(node.attrib for node in ancestors):
                    unsupported(context, 'configuration merge attributes are unsupported')
                if artifact in locations:
                    unsupported(context, 'multiple filter configurations; also declared at ' + locations[artifact])
                locations[artifact] = context
                rule = rules.setdefault(artifact, {'includes': None, 'excludes': []})
                seen = set()
                for node in filters:
                    context, _ = filter_context(pom, root, node)
                    if node.tag in seen or node.tag.endswith('File'):
                        unsupported(context, 'duplicate or external filter: ' + (node.text or '').strip())
                    seen.add(node.tag)
                    singular = 'include' if node.tag == 'includes' else 'exclude'
                    patterns = [(child.text or '').strip() for child in node]
                    if not patterns or any(child.tag != singular for child in node):
                        unsupported(context, 'empty or unresolved filter')
                    for pattern in patterns:
                        if node.tag == 'includes' and pattern not in DEFAULT_INCLUDES[artifact]:
                            unsupported(context, 'unsupported include ' + repr(pattern))
                        literal = pattern.removeprefix('**/')
                        if node.tag == 'excludes' and pattern != '**/*$*' and not re.fullmatch(r'[A-Za-z0-9_$/-]+\.(?:java|class)', literal):
                            unsupported(context, 'unsupported exclude ' + repr(pattern))
                    rule[node.tag] = patterns
    return rules


def matches(pattern, source):
    prefix = '(?:.*/)?' if pattern.startswith('**/') else ''
    literal = pattern.removeprefix('**/')
    expression = re.escape(literal).replace(r'\*', '[^/]*')
    return re.fullmatch(prefix + expression, source) is not None


def eligible(names, rules):
    from selected_test_reports import is_integration
    result = set()
    for name in names:
        rule = rules.get('maven-failsafe-plugin' if is_integration(None, name) else 'maven-surefire-plugin')
        if rule is None:
            result.add(name)
            continue
        source = name.replace('.', '/') + '.java'
        included = rule['includes'] is None or any(matches(pattern, source) for pattern in rule['includes'])
        excluded = any(matches(pattern.removesuffix('.class') + '.java' if pattern.endswith('.class') else pattern, source)
                       for pattern in rule['excludes'])
        if included and not excluded:
            result.add(name)
    return result
