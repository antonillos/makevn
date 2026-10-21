"""Static contract consumers and automatic conservative shared-resource scope."""
import pathlib
import re


class ExhaustiveScopeRequired(ValueError):
    """Analysis completed, but a safe focused plan is unavailable."""


def literal_path(value):
    if not isinstance(value, str) or not re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_./-]*', value):
        raise ValueError('Impact paths must be literal relative paths')
    path = pathlib.PurePosixPath(value)
    if any(part in {'', '.', '..'} for part in value.split('/')):
        raise ValueError('Impact paths cannot contain empty, dot or parent components')
    return path


def resource_owners(path, rules):
    owners = set()
    if path.resolve() != path:
        raise ValueError('Refusing linked shared-resource input: ' + str(path))
    for prefix, modules in rules:
        if path.is_relative_to(prefix):
            owners.update(modules)
    return owners


def automatic_resource_rules(repo, base, modules, parse):
    """Unproven narrower ownership means every declared Maven suite, not guesses."""
    root = parse((base / 'pom.xml').read_text())
    if not modules or root.findtext('packaging', 'jar') != 'pom':
        return []
    for kind, allowed in [('main', {'config', 'resources'}), ('test', {'resources'})]:
        directory = base / 'src' / kind
        if directory.is_dir() and any(path.name not in allowed for path in directory.iterdir()):
            return []  # There may be a root-level executable/test owner.
    prefix = base / 'src/test/resources'
    if prefix.resolve() != prefix:
        raise ValueError('Refusing linked shared-resource prefix: ' + str(prefix))
    for owner in modules:
        literal_path(owner)
    return [(prefix, set(modules))]


def shared_resource_owners(repo, base, modules, path, parse):
    automatic = automatic_resource_rules(repo, base, modules, parse)
    return resource_owners(path, automatic)


def reactor_consumers(base, modules, owner, parse):
    """Overselect the reverse closure, including inherited/profile dependencies."""
    for name in modules:
        literal_path(name)
    roots = {name: parse((base / name / 'pom.xml').read_text()) for name in {'.', *modules}}
    by_path = {(base / name / 'pom.xml').resolve(): name for name in roots}
    models = {}

    def model(name, visiting=()):
        if name in models:
            return models[name]
        if name in visiting:
            raise ValueError('Cyclic local POM parents')
        root = roots[name]
        parent = root.find('parent')
        inherited, ancestors, profile_keys = {}, [], set()
        parent_name = None
        if parent is not None:
            relative = parent.findtext('relativePath', '../pom.xml')
            parent_name = by_path.get((base / name / relative).resolve()) if relative else None
            if parent_name is not None:
                ancestor = model(parent_name, (*visiting, name))
                expected = tuple(parent.findtext(key, '').strip() for key in ('groupId', 'artifactId', 'version'))
                if expected != ancestor['coordinate']:
                    raise ValueError('Local parent coordinates do not match for ' + name)
                inherited = dict(ancestor['properties'])
                ancestors = ancestor['roots']
                profile_keys.update(ancestor['profile_keys'])
        profile_keys.update(node.tag for node in root.findall('./profiles/profile/properties/*'))
        properties = {**inherited, **{node.tag: (node.text or '').strip() for node in root.findall('./properties/*')}}

        def resolve(value, active=()):
            def replace(match):
                key = match.group(1)
                if key in active or key in profile_keys or key not in properties:
                    raise ValueError('Unresolved or profile-dependent Maven coordinate: ' + value)
                return resolve(properties[key], (*active, key))
            result = re.sub(r'\$\{([^}]+)\}', replace, value.strip())
            if '${' in result:
                raise ValueError('Malformed Maven coordinate: ' + value)
            return result

        group = resolve(root.findtext('groupId') or root.findtext('./parent/groupId', ''))
        version = resolve(root.findtext('version') or root.findtext('./parent/version', ''))
        artifact = resolve(root.findtext('artifactId', ''))
        if not all((group, version, artifact)):
            raise ValueError('Incomplete reactor coordinates for ' + name)
        for prefix in ('project', 'pom'):
            properties.update({prefix + '.groupId': group, prefix + '.artifactId': artifact, prefix + '.version': version})
        result = dict(coordinate=(group, artifact, version), properties=properties, roots=[*ancestors, root], profile_keys=profile_keys, resolve=resolve, parent=parent_name)
        models[name] = result
        return result

    coordinates = {}
    for name in sorted(roots):
        coordinate = model(name)['coordinate'][:2]
        if coordinate in coordinates:
            raise ValueError('Duplicate reactor groupId/artifactId: ' + ':'.join(coordinate))
        coordinates[coordinate] = name
    reverse = {name: set() for name in roots}
    for name in sorted(roots):
        current = model(name)
        if current['parent'] is not None:
            reverse[current['parent']].add(name)
        for root in current['roots']:
            # Managed dependencies are declarations of versions, not consumers.
            managed = {node for manager in root.iter('dependencyManagement') for node in manager.iter('dependency')}
            dependencies = [node for node in root.iter('dependency') if node not in managed]
            dependencies += root.findall('.//artifactItem')
            # Invoked local build plugins are consumers; pluginManagement alone is not.
            dependencies += root.findall('.//build/plugins/plugin')
            dependencies += root.findall('.//build/extensions/extension')
            for dependency in dependencies:
                group = dependency.findtext('groupId', 'org.apache.maven.plugins' if dependency.tag == 'plugin' else '')
                coordinate = (current['resolve'](group), current['resolve'](dependency.findtext('artifactId', '')))
                if not all(coordinate):
                    raise ValueError('Incomplete dependency coordinates in ' + name)
                target = coordinates.get(coordinate)
                if target is not None:
                    reverse[target].add(name)
    selected, pending = {owner}, [owner]
    while pending:
        for consumer in reverse[pending.pop()] - selected:
            selected.add(consumer)
            pending.append(consumer)
    if '.' in selected:
        raise ExhaustiveScopeRequired('Contract has a Maven-root consumer; use --exhaustive')
    return selected


def leaf_bump_owners(repo, base, owner, current, changed, modules, parse):
    """Only leaf version properties used in dependencies/known unpack artifacts."""
    if owner not in modules or not changed or any(not key.endswith('version') for key in changed) or current.findall('./modules/module') or current.findall('./profiles/profile/modules/module'):
        return None
    if any(not current.findtext('./properties/' + key, '').strip() or '${' in current.findtext('./properties/' + key, '') for key in changed):
        return None
    tokens = {'${' + key + '}' for key in changed}
    versions = current.findall('./dependencies/dependency/version')
    allowed = set(versions)
    used = set()
    extra_owners = set()
    dependencies = {tuple(node.findtext(key, '') for key in ('groupId', 'artifactId')) for node in current.findall('./dependencies/dependency') if node.findtext('version') in tokens}
    for plugin in current.findall('./build/plugins/plugin'):
        items = plugin.findall('.//artifactItem')
        relevant = [item for item in items if item.findtext('version') in tokens]
        if not relevant:
            continue
        if plugin.findtext('groupId', 'org.apache.maven.plugins') != 'org.apache.maven.plugins' or plugin.findtext('artifactId') != 'maven-dependency-plugin':
            return None
        for item in relevant:
            if tuple(item.findtext(key, '') for key in ('groupId', 'artifactId')) not in dependencies:
                return None
            allowed.add(item.find('version'))
        for output in plugin.findall('.//outputDirectory'):
            value = (output.text or '').strip().replace('${project.basedir}', str(base / owner)).replace('${basedir}', str(base / owner)).replace('${project.build.directory}', str(base / owner / 'target'))
            if '${' in value or not value:
                return None
            path = (base / owner / value).resolve()
            if not path.is_relative_to(base / owner):
                mapped = shared_resource_owners(repo, base, modules, path, parse)
                if not mapped:
                    return None
                extra_owners.update(mapped)
    for node in current.iter():
        if any(token in value for token in tokens for value in node.attrib.values()):
            return None
        if any(token in (node.text or '') for token in tokens):
            if node not in allowed or node.text not in tokens:
                return None
            used.add(node.text)
    if used != tokens or not dependencies:
        return None
    # A property reused by a local descendant cannot be treated as leaf-only.
    for name in modules - {owner}:
        other = parse((base / name / 'pom.xml').read_text())
        if any(token in (node.text or '') for token in tokens for node in other.iter()):
            return None
    return reactor_consumers(base, modules, owner, parse) | extra_owners
