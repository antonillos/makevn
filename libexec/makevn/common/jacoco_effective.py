"""Classify JaCoCo bindings in a Maven-generated effective model.

This inspects configuration only; it does not establish that a JVM ran the agent.
"""
import json
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET


def classify_project(project, user_skip=None):
    artifact = project.findtext('artifactId', '<unknown>')
    plugins = [p for p in project.findall('build/plugins/plugin')
               if p.findtext('artifactId') == 'jacoco-maven-plugin']
    if not plugins:
        return {'project': artifact, 'status': 'absent', 'reason': 'no active JaCoCo build plugin'}
    if len(plugins) != 1 or plugins[0].findtext('groupId') != 'org.jacoco':
        return {'project': artifact, 'status': 'unknown', 'reason': 'ambiguous JaCoCo plugin coordinates'}
    plugin = plugins[0]
    uncertain = False
    for execution in plugin.findall('executions/execution'):
        if 'prepare-agent' not in [(g.text or '').strip() for g in execution.findall('goals/goal')]:
            continue
        phase = (execution.findtext('phase') or '').strip()
        if phase == 'none':
            continue
        if phase and phase not in ('validate', 'initialize', 'generate-sources', 'process-sources', 'generate-resources', 'process-resources', 'compile', 'process-classes', 'generate-test-sources', 'process-test-sources', 'generate-test-resources', 'process-test-resources', 'test-compile', 'process-test-classes'):
            uncertain = True
            continue
        skip = execution.findtext('configuration/skip', plugin.findtext('configuration/skip'))
        if skip is None:
            skip = user_skip if user_skip is not None else '${jacoco.skip}'
        skip = skip.strip()
        match = re.fullmatch(r'\$\{([^}]+)\}', skip)
        if match:
            skip = user_skip if match[1] == 'jacoco.skip' and user_skip is not None else skip
        elif user_skip is not None and skip.lower() in ('true', 'false') and user_skip.lower() != skip.lower():
            uncertain = True
            continue
        if skip.lower() == 'false':
            return {'project': artifact, 'status': 'configured', 'reason': 'active prepare-agent execution',
                    'execution': execution.findtext('id', 'default'), 'phase': phase or 'initialize'}
        if skip.lower() != 'true':
            uncertain = True
    if any((g.text or '').strip() == 'prepare-agent-integration' for g in plugin.findall('executions/execution/goals/goal')):
        uncertain = True
    if uncertain:
        return {'project': artifact, 'status': 'unknown', 'reason': 'JaCoCo phase, scope or skip property is unresolved'}
    return {'project': artifact, 'status': 'absent', 'reason': 'no enabled prepare-agent execution'}


def classify(path, user_skip=None):
    root = ET.parse(path).getroot()
    for node in root.iter():
        node.tag = node.tag.rsplit('}', 1)[-1]
    projects = [root] if root.tag == 'project' else root.findall('project')
    if not projects:
        raise ValueError('effective model contains no Maven projects')
    return [classify_project(project, user_skip) for project in projects]


def main():
    try:
        overrides = [arg.partition('=')[2] if '=' in arg else 'true' for arg in sys.argv[2:]
                     if arg == '-Djacoco.skip' or arg.startswith('-Djacoco.skip=')]
        print(json.dumps({'projects': classify(Path(sys.argv[1]), overrides[-1] if overrides else None),
                          'scope': 'effective model; agent execution not verified'}))
    except (OSError, ET.ParseError, ValueError, IndexError) as error:
        print(json.dumps({'projects': [], 'status': 'unknown', 'reason': str(error)}))
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
