"""Module-qualified Java facts for literal local Maven reactors."""
import test_impact as impact

KIND = 'progressive-reactor-v1'


def modules(base):
    from changes_scope import declared_modules, parse
    result = declared_modules(base, parse((base / 'pom.xml').read_text()))
    if result is None:
        raise ValueError('unresolved or profile-dependent reactor layout')
    return sorted({'.', *result}) if result else []


def validate(base, owners):
    from changes_scope import parse
    from reactor_impact import reactor_consumers
    for owner in owners:
        directory = base / owner
        # Aggregators are validated separately from the legacy isolated layout.
        root = parse((directory / 'pom.xml').read_text())
        for tag in ['sourceDirectory', 'testSourceDirectory', 'outputDirectory', 'testOutputDirectory']:
            if root.find('./build/' + tag) is not None or root.findall('./profiles/profile/build/' + tag):
                raise ValueError('custom Java layout requires complete owner suites')
        if any(goal.text in {'add-source', 'add-test-source'} for goal in root.findall('.//goals/goal')):
            raise ValueError('additional Java source roots require complete owner suites')
        for name in ['generated-sources', 'generated-test-sources']:
            if any((directory / 'target' / name).rglob('*.java')):
                raise ValueError('generated Java sources have no validated impact graph')
        if impact.maven_flag_tokens(directory):
            # Flags are interpreted by Maven; do not guess effective source models.
            if any('maven.repo.local' in flag or flag.startswith(('-s', '-gs', '--settings', '--global-settings'))
                   for flag in impact.maven_flag_tokens(directory)):
                raise ValueError('custom Maven settings/repository evidence is unsupported')
    # Validate dependency coordinates before publishing a supposedly usable map.
    for owner in set(owners) - {'.'}:
        reactor_consumers(base, set(owners) - {'.'}, owner, parse)


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
