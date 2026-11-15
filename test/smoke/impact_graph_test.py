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

    def test_depth_limit_and_all(self):
        parsed = {'src/main/java/A.java': fact('A', []),
                  'src/main/java/B.java': fact('B', ['A'])} | {
            f'src/test/java/Test{i}.java': fact(f'Test{i}', ['B']) for i in range(150)}
        value, index = {'facts': parsed}, impact.graph_index(parsed)
        shallow = impact_graph.describe(value, index, 'A', depth=1, show_all=True)
        self.assertEqual({node['id'] for node in shallow['nodes']}, {'A', 'B'})
        full = impact_graph.describe(value, index, 'A', depth=2, show_all=True)
        self.assertEqual(len(full['nodes']), 152)
        limited = impact_graph.describe(value, index, 'A', depth=2, limit=50)
        self.assertIn('100 more', impact_graph.render(limited))
        with self.assertRaises(ValueError):
            impact_graph.describe(value, index, 'A', depth=0)


if __name__ == '__main__':
    unittest.main()
