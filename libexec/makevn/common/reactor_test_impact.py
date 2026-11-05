"""Module-qualified Java facts for literal local Maven reactors."""
import test_impact as impact

KIND = 'progressive-reactor-v1'


def modules(base):
    from changes_scope import declared_modules, parse
    result = declared_modules(base, parse((base / 'pom.xml').read_text()))
    if result is None:
        raise ValueError('unresolved or profile-dependent reactor layout')
    return sorted({'.', *result}) if result else []


def validate(base, owners, skip_additional=False):
    from changes_scope import parse
    from reactor_impact import reactor_consumers
    if not skip_additional:
        for owner in owners:
            root = parse((base / owner / 'pom.xml').read_text())
            if any(goal.text in {'add-source', 'add-test-source'} for goal in root.findall('.//goals/goal')):
                raise ValueError('additional Java source roots require complete owner suites')
    for owner in owners:
        directory = base / owner
        # Aggregators are validated separately from the legacy isolated layout.
        root = parse((directory / 'pom.xml').read_text())
        for tag in ['sourceDirectory', 'testSourceDirectory', 'outputDirectory', 'testOutputDirectory']:
            if root.find('./build/' + tag) is not None or root.findall('./profiles/profile/build/' + tag):
                raise ValueError('custom Java layout requires complete owner suites')
        for name in ['generated-sources', 'generated-test-sources']:
            if not skip_additional and any((directory / 'target' / name).rglob('*.java')):
                raise ValueError('generated Java sources have no validated impact graph')
        if impact.maven_flag_tokens(directory):
            # Flags are interpreted by Maven; do not guess effective source models.
            if any('maven.repo.local' in flag or flag.startswith(('-s', '-gs', '--settings', '--global-settings'))
                   for flag in impact.maven_flag_tokens(directory)):
                raise ValueError('custom Maven settings/repository evidence is unsupported')
    # Validate dependency coordinates before publishing a supposedly usable map.
    for owner in set(owners) - {'.'}:
        reactor_consumers(base, set(owners) - {'.'}, owner, parse)


def additional_roots_preview(base, owners):
    """Describe declarations without claiming Maven's effective model is known."""
    from changes_scope import parse
    from reactor_impact import reactor_consumers
    roots, unresolved, affected = [], [], set()
    models = {owner: parse((base / owner / 'pom.xml').read_text()) for owner in owners}
    custom_build_directory = any(model.find('./build/directory') is not None or
                                 model.findall('./profiles/profile/build/directory')
                                 for model in models.values())
    pom_paths = {(base / owner / 'pom.xml').resolve() for owner in owners}
    external_parent = any(
        not (relative := model.findtext('./parent/relativePath', '../pom.xml')) or
        (base / owner / relative).resolve() not in pom_paths
        for owner, model in models.items() if model.find('./parent') is not None)
    for owner, model in models.items():
        for plugin in model.findall('.//plugin'):
            goals = [node.text for node in plugin.findall('.//goals/goal')
                     if node.text in {'add-source', 'add-test-source'}]
            if not goals:
                continue
            configurations = plugin.findall('./configuration/sources/source') + plugin.findall('./executions/execution/configuration/sources/source')
            values = [(node.text or '').strip() for node in configurations]
            simple = (plugin in model.findall('./build/plugins/plugin') and
                      plugin.findtext('groupId') == 'org.codehaus.mojo' and
                      len(plugin.findall('./executions/execution')) == 1 and
                      plugin.find('./configuration') is None and not external_parent and
                      not any(other != owner and any(
                          node.findtext('artifactId') == 'build-helper-maven-plugin'
                          for node in other_model.findall('.//plugin'))
                          for other, other_model in models.items()))
            inherited = plugin.findtext('inherited', 'true').strip() != 'false' and any(
                other != owner and (base / other / other_model.findtext('./parent/relativePath', '../pom.xml')).resolve()
                == (base / owner / 'pom.xml').resolve() for other, other_model in models.items()
                if other_model.find('./parent') is not None)
            if not values:
                values = ['<unspecified sources>']
            for value in values:
                expanded = value.replace('${project.basedir}', str(base / owner)).replace('${basedir}', str(base / owner)).replace('${project.build.directory}', str(base / owner / 'target'))
                path = (base / owner / expanded).resolve()
                known = (value and '${' not in expanded and not value.startswith('<') and
                         not (custom_build_directory and '${project.build.directory}' in value) and
                         path.is_relative_to((base / owner).resolve()) and not inherited and simple and
                         plugin.findtext('artifactId') == 'build-helper-maven-plugin')
                item = {'root': path.relative_to(base).as_posix() if known else value, 'owner': owner if known else None,
                        'declared_in': owner}
                (roots if known else unresolved).append(item)
            if owner == '.':
                unresolved.append({'root': '<Maven-root owner>', 'owner': None, 'declared_in': owner})
            else:
                affected.add(owner)
    if not roots and not unresolved:
        return None
    try:
        validate(base, owners, skip_additional=True)
        suites = set().union(*(reactor_consumers(base, set(owners) - {'.'}, owner, parse) for owner in affected))
    except ValueError as error:
        unresolved.append({'root': '<consumer scope: ' + str(error) + '>', 'owner': None, 'declared_in': None})
        suites = set()
    return {'status': 'unsupported' if unresolved else 'requires_exhaustive_scope',
            'roots': roots, 'unresolved_roots': unresolved,
            'suites': sorted(suites) if not unresolved else [],
            'next_action': 'Run makevn verify-changes --exhaustive after reviewing the changes.',
            'tests_executed': False}


def facts(base, owners, java):
    paths, ownership = [], {}
    for owner in owners:
        directory = base / owner
        for kind in ['main', 'test']:
            for source in (directory / 'src' / kind / 'java').rglob('*.java'):
                paths.append(source)
                ownership[source.relative_to(base).as_posix()] = owner
    result = impact.facts(base, java, sorted(paths))
    for source, item in result.items():
        owner = ownership[source]
        item.update(owner=owner, name=item['class'], **{'class': owner + '::' + item['class']})
    return result


def inputs(repo, base, owners):
    result = impact.inputs(repo, base)
    for owner in owners:
        for kind in ['main', 'test']:
            for source in (base / owner / 'src' / kind / 'resources').rglob('*'):
                if source.is_file():
                    result[source.relative_to(repo).as_posix()] = impact.digest(source)
    return result


def is_source(source, kind):
    return '/src/' + kind + '/java/' in '/' + source


def identity(value, owner, name):
    return owner + '::' + name if value['kind'] == KIND else name


def local_names(value, names, owner):
    if value['kind'] != KIND:
        return set(names)
    return {name.split('::', 1)[1] for name in names if name.startswith(owner + '::')}
