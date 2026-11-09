"""Recover constructor metrics omitted by the pinned source analyzer."""
from pathlib import Path
import xml.etree.ElementTree as ET

from jacoco_html import method_range


def constructor_entries(xml_path, source_root, existing):
    entries = []
    for package in ET.parse(xml_path).getroot().findall('package'):
        for node in package.findall('class'):
            name = node.get('name', '').replace('/', '.')
            relative = Path('src/main/java') / package.get('name', '') / node.get('sourcefilename', '')
            source = Path(source_root) / relative
            if not source.is_file():
                continue
            for method in node.findall('method'):
                if method.get('name') != '<init>':
                    continue
                line = int(method.get('line', '0'))
                if any(e.get('class') == name and int(e.get('line', 0)) <= line <= int(e.get('end_line') or e.get('line', 0)) for e in existing):
                    continue
                counters = {c.get('type'): c for c in method.findall('counter')}
                if not {'INSTRUCTION', 'COMPLEXITY'} <= counters.keys():
                    raise ValueError(f'incomplete constructor metrics: {name}:{line}')
                instruction = counters['INSTRUCTION']
                covered = int(instruction.get('covered', '0'))
                total = covered + int(instruction.get('missed', '0'))
                if not total:
                    raise ValueError(f'empty constructor instruction count: {name}:{line}')
                try:
                    start, end = method_range(source.read_text(), line, None,
                                              constructor_name=name.rsplit('.', 1)[-1].rsplit('$', 1)[-1])
                except ValueError:
                    # Implicit constructors have no explicit declaration to associate.
                    continue
                counter = counters['COMPLEXITY']
                complexity = int(counter.get('covered', '0')) + int(counter.get('missed', '0'))
                coverage = covered / total
                entries.append(dict(file=relative.as_posix(), **{'class': name},
                                    method='<init>' + method.get('desc', ''), line=start, end_line=end,
                                    complexity=complexity, coverage_percent=coverage * 100,
                                    crap=complexity ** 2 * (1 - coverage) ** 3 + complexity,
                                    status='measured'))
    return entries
