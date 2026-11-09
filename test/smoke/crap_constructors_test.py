"""Constructor recovery uses actual per-method counters and source ranges."""
import sys
from pathlib import Path
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'libexec/makevn/crap'))
from constructors import constructor_entries
from jacoco_html import method_range


class ConstructorTests(unittest.TestCase):
    def test_overloaded_constructors_and_partial_coverage(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'src/main/java/demo/Failure.java'
            source.parent.mkdir(parents=True)
            source.write_text('package demo;\nclass Failure {\n Failure() { super(); }\n Failure(int n) { if (n < 0) throw new RuntimeException(); }\n}\n')
            xml = root / 'jacoco.xml'
            xml.write_text('''<report><package name="demo"><class name="demo/Failure" sourcefilename="Failure.java">
<method name="&lt;init&gt;" desc="()V" line="3"><counter type="INSTRUCTION" covered="3" missed="0"/><counter type="COMPLEXITY" covered="1" missed="0"/></method>
<method name="&lt;init&gt;" desc="(I)V" line="4"><counter type="INSTRUCTION" covered="5" missed="5"/><counter type="COMPLEXITY" covered="1" missed="1"/></method>
</class></package></report>''')
            entries = constructor_entries(xml, root, [])
            self.assertEqual([e['line'] for e in entries], [3, 4])
            self.assertEqual([e['crap'] for e in entries], [1, 2.5])
            self.assertEqual(constructor_entries(xml, root, entries), [])

    def test_same_name_method_and_new_expression_are_not_constructors(self):
        for source in ('class Owner { void Owner() {} }',
                       'class Example { Object value = new Owner() {}; }'):
            with self.subTest(source=source), self.assertRaises(ValueError):
                method_range(source, 1, None, constructor_name='Owner')

    def test_anonymous_initializer_is_not_an_explicit_constructor(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'src/main/java/demo/Owner.java'
            source.parent.mkdir(parents=True)
            source.write_text('package demo;\nclass Owner {\n Runnable task = new Runnable() {\n  { System.out.println("init"); }\n  public void run() { System.out.println("changed"); }\n };\n}\n')
            xml = root / 'jacoco.xml'
            xml.write_text('''<report><package name="demo"><class name="demo/Owner$1" sourcefilename="Owner.java">
<method name="&lt;init&gt;" desc="()V" line="3"><counter type="INSTRUCTION" covered="1" missed="9"/><counter type="COMPLEXITY" covered="1" missed="4"/></method>
</class></package></report>''')
            self.assertEqual(constructor_entries(xml, root, []), [])


if __name__ == '__main__':
    unittest.main()
