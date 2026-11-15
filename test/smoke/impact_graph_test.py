"""Graph views preserve conservative selection and bound their output."""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'libexec/makevn/common'))
import impact_graph
import progressive_impact as impact


def fact(name, names, owner='.'):
    return {'class': owner + '::' + name if owner != '.' else name,
            'declared': [name], 'names': names, 'owner': owner}


class GraphTests(unittest.TestCase):
    def test_selection_and_observations_are_distinct(self):
        parsed = {'a/src/main/java/A.java': fact('A', []),
                  'a/src/main/java/B.java': fact('B', ['A']),
                  'a/src/test/java/BTest.java': fact('BTest', ['B']),
                  'a/src/test/java/ObservedTest.java': fact('ObservedTest', [])}
        index = impact.graph_index(parsed, {'ObservedTest': ['A']})
        self.assertEqual(impact.consumers(parsed, {'A'}, index), {'A', 'B', 'BTest'})
        graph = impact_graph.describe({'facts': parsed}, index, 'A', 'compatible')
        self.assertTrue(any(edge['observed'] and edge['target'] == 'ObservedTest' for edge in graph['edges']))
        self.assertTrue(any(edge['repeated'] for edge in graph['edges']))

    def test_ambiguous_module_identity_and_bounded_output(self):
        parsed = {f'{owner}/src/main/java/A.java': fact('A', [], owner) for owner in ('one', 'two')}
        with self.assertRaisesRegex(ValueError, 'Ambiguous class'):
            impact_graph.describe({'facts': parsed}, impact.graph_index(parsed), 'A')
        parsed = {'src/main/java/Root.java': fact('Root', [])} | {
            f'src/test/java/Test{i}.java': fact(f'Test{i}', ['Root']) for i in range(120)}
        graph = impact_graph.describe({'facts': parsed}, impact.graph_index(parsed), 'Root')
        self.assertEqual(len(graph['nodes']), 100)
        self.assertTrue(graph['truncated'])
        self.assertGreater(graph['omitted'], 0)
        rendered = impact_graph.render(graph)
        self.assertIn('Tests: 99', rendered)
        self.assertIn('89 more', rendered)
        self.assertNotIn('Root ->', rendered)
        self.assertLess(len(rendered.splitlines()), 25)


if __name__ == '__main__':
    unittest.main()
