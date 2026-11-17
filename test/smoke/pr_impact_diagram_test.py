"""Bounded PR diagrams summarize the effective plan without invented dependency paths."""
from pathlib import Path
import json
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'libexec/makevn/common'))
from pr_impact_diagram import summarize


class DiagramTests(unittest.TestCase):
    def test_class_and_suite_scope_use_the_effective_plan(self):
        graph = summarize('develop...HEAD', 'focused', False, 'src/Price.java\nsrc/Price.java\n',
                          'core\t*\nservice\texample.PriceTest,example.OtherTest', 'core,service')
        self.assertEqual(graph['changedInputs'], 1)
        self.assertIn('Complete module suite', graph['markdown'])
        self.assertIn('2 selected test classes', graph['markdown'])
        self.assertIn('No tests have been executed by this preview', graph['markdown'])
        self.assertNotIn('Price.java -->', graph['markdown'])

    def test_large_scope_stays_small_and_explicitly_groups_remaining_modules(self):
        plan = '\n'.join(f'module{i}\t' + ','.join(f'example.Test{j}' for j in range(200)) for i in range(50))
        graph = summarize('HEAD', 'focused', False, '\n'.join(f'src/File{i}.java' for i in range(100)), plan, '')
        self.assertEqual(graph['groupedModules'], 46)
        self.assertLess(graph['markdown'].count('["'), 9)
        self.assertLess(len(graph['markdown']), 2500)
        self.assertIn('9200 selected classes', graph['markdown'])
        exhaustive = summarize('HEAD', 'exhaustive', False, 'pom.xml', '', ','.join(f'module{i}' for i in range(50)))
        self.assertLessEqual(exhaustive['markdown'].count('["'), 8)
        self.assertIn('Not enumerated in this summary', exhaustive['markdown'])

    def test_unresolved_and_empty_scopes_do_not_claim_test_selection(self):
        blocked = summarize('HEAD', 'focused', True, 'pom.xml', '.\texample.Test', '.')
        self.assertEqual(blocked['selectedModules'], 0)
        self.assertEqual(blocked['status'], 'requires_exhaustive')
        self.assertIn('Focused scope unresolved', blocked['markdown'])
        empty = summarize('HEAD', 'focused', False, '', '', '')
        self.assertEqual(empty['status'], 'skip')
        exhaustive = summarize('HEAD', 'exhaustive', False, 'pom.xml', '', 'api,core')
        self.assertIn('Upstream dependency suites', exhaustive['markdown'])
        self.assertIn('Complete module suite', exhaustive['markdown'])
        whole = summarize('HEAD', 'exhaustive', False, 'pom.xml', '', '.')
        self.assertIn('Whole Maven project', whole['markdown'])
        self.assertIn('Complete reactor suites', whole['markdown'])

    def test_repository_labels_cannot_add_mermaid_statements_or_markdown_fences(self):
        bad = 'evil"] --> injected["bad```<script>'
        graph = summarize(bad, 'focused', False, bad, bad + '\t*', bad)
        self.assertNotIn('<script>', graph['markdown'])
        self.assertNotIn(' --> injected', graph['markdown'])
        self.assertEqual(graph['markdown'].count('```'), 2)

    def test_cli_writes_the_same_markdown_as_the_mcp_payload(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'reports/impact.md'
            args = ['HEAD', 'focused', 'false', str(output)]
            payload = '\0'.join(['src/Price.java', '.\texample.PriceTest', '.'])
            result = subprocess.run([sys.executable, str(ROOT / 'libexec/makevn/common/pr_impact_diagram.py'), *args],
                                    input=payload, check=True, capture_output=True, text=True)
            self.assertEqual(output.read_text(), json.loads(result.stdout)['markdown'])


if __name__ == '__main__':
    unittest.main()
