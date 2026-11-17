"""Small Mermaid summaries of effective verification plans for PR descriptions."""
import json
from pathlib import Path
import sys

from selection_report import plans

MAX_MODULES = 4
MAX_EXAMPLES = 3


def label(value):
    text = ' '.join(value.split())
    text = text if len(text) <= 70 else text[:67] + '...'
    return ''.join(char if char.isalnum() or char in ' _./:,-()' else '#' + str(ord(char)) + ';'
                   for char in text)


def node(identifier, headings):
    return '  ' + identifier + '["' + '<br/>'.join(label(text) for text in headings) + '"]'


def summarize(reference, mode, blocked, changed, plan, modules):
    inputs = sorted(set(filter(None, changed.splitlines())))
    selected = plans(plan) if mode == 'focused' else {
        owner: {'mode': 'suite', 'classes': []} for owner in filter(None, modules.split(','))}
    selected = {} if blocked else dict(sorted(selected.items()))
    lines = ['flowchart LR', node('changes', ['Changed files: ' + str(len(inputs))] +
                               [Path(name).name for name in inputs[:MAX_EXAMPLES]] +
                               (['and ' + str(len(inputs) - MAX_EXAMPLES) + ' more'] if len(inputs) > MAX_EXAMPLES else []))]
    if blocked:
        status = 'requires_exhaustive'
        lines += [node('plan', ['Focused scope unresolved', 'Review exhaustive preview']), '  changes --> plan']
    elif not selected:
        status = 'skip'
        lines += [node('plan', ['No verification suites selected']), '  changes --> plan']
    else:
        status = 'planned'
        title = 'Focused plan' if mode == 'focused' else 'Exhaustive plan'
        lines += [node('plan', [title, 'Planned scopes: ' + str(len(selected))]), '  changes -->|scope analysis| plan']
        for index, (owner, scope) in enumerate(list(selected.items())[:MAX_MODULES]):
            headings = ['Root module' if owner == '.' else owner]
            if mode != 'focused' and owner == '.':
                headings = ['Whole Maven project']
            if scope['mode'] == 'suite':
                headings.append('Complete reactor suites' if mode != 'focused' and owner == '.' else 'Complete module suite')
            else:
                names = scope['classes']
                headings.append(str(len(names)) + ' selected test classes')
                headings.extend(name.rsplit('.', 1)[-1] for name in names[:MAX_EXAMPLES])
                if len(names) > MAX_EXAMPLES:
                    headings.append('and ' + str(len(names) - MAX_EXAMPLES) + ' more')
            lines += [node('m' + str(index), headings), '  plan --> m' + str(index)]
        if len(selected) > MAX_MODULES:
            hidden = list(selected.values())[MAX_MODULES:]
            suites = sum(scope['mode'] == 'suite' for scope in hidden)
            classes = sum(len(scope['classes']) for scope in hidden if scope['mode'] == 'classes')
            lines += [node('other', [str(len(hidden)) + ' additional modules', str(suites) + ' complete suites',
                                    str(classes) + ' selected classes in other modules']), '  plan --> other']
    if selected and mode != 'focused' and '.' not in selected:
        lines += [node('dependencies', ['Upstream dependency suites', 'Included by Maven -am',
                                        'Not enumerated in this summary']), '  plan --> dependencies']
    lines += ['  classDef changed fill:#ffedd5,stroke:#c2410c',
              '  classDef scope fill:#dbeafe,stroke:#1d4ed8', '  class changes changed', '  class plan scope']
    markdown = ('### Planned verification scope\n\nComparison: `' + label(reference) + '`.\n\n```mermaid\n' +
                '\n'.join(lines) + '\n```\n\nGrouped plan summary, not individual dependency paths. '
                'Test names are examples of the selected classes. '
                'No tests have been executed by this preview. Re-run after edits; full CI remains required.\n')
    return {'format': 'mermaid', 'markdown': markdown, 'status': status,
            'changedInputs': len(inputs), 'selectedModules': len(selected),
            'groupedModules': max(0, len(selected) - MAX_MODULES)}


def main(args):
    reference, mode, blocked, destination = args
    changed, plan, modules = sys.stdin.read().split('\0')
    result = summarize(reference, mode, blocked == 'true', changed, plan, modules)
    if destination:
        output = Path(destination)
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(result['markdown'])
    print(json.dumps(result))


if __name__ == '__main__':
    main(sys.argv[1:])
