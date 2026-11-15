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
        self.assertEqual(len(graph['nodes']), 11)
        self.assertEqual(graph['reached_nodes'], 121)
        self.assertTrue(graph['truncated'])
        self.assertGreater(graph['omitted'], 0)
        rendered = impact_graph.render(graph)
        self.assertEqual(graph['layers'][1]['test'], 120)
        self.assertIn('Hidden classes due to display limit: 110', rendered)
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
        self.assertIn('Hidden classes due to display limit: 100', impact_graph.render(limited))
        with self.assertRaises(ValueError):
            impact_graph.describe(value, index, 'A', depth=0)

    def test_display_limit_does_not_stop_deeper_traversal(self):
        parsed = {'src/main/java/Root.java': fact('Root', [])} | {
            f'src/main/java/Wide{i}.java': fact(f'Wide{i}', ['Root']) for i in range(150)}
        parsed['src/main/java/Deep.java'] = fact('Deep', ['Wide149'])
        parsed['src/test/java/DeepTest.java'] = fact('DeepTest', ['Deep'])
        value, index = {'facts': parsed}, impact.graph_index(parsed)
        two = impact_graph.describe(value, index, 'Root', depth=2, limit=1)
        three = impact_graph.describe(value, index, 'Root', depth=3, limit=1)
        self.assertEqual(two['reached_nodes'] + 1, three['reached_nodes'])
        self.assertEqual(three['layers'][3]['test'], 1)
        self.assertIn('[L3, test', impact_graph.render(three))
        self.assertIn('DeepTest', impact_graph.render(three))
        by_name = {node['id']: node for node in three['nodes']}
        self.assertEqual(by_name['DeepTest']['parent'], 'Deep')
        self.assertEqual(by_name['Deep']['parent'], 'Wide149')
        self.assertIn('└── DeepTest [L3, test]', impact_graph.render(three))
        self.assertNotIn('\t', impact_graph.render(three))


if __name__ == '__main__':
    unittest.main()
