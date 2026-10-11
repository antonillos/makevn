import contextlib
import io
import importlib.util
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("enforcer", ROOT / "libexec/makevn/jdk/enforcer.py")
enforcer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(enforcer)


class EnforcerTests(unittest.TestCase):
    def test_ranges(self):
        cases = [
            ("[25,26)", "25.0.2", True), ("[25,26)", "26", False),
            ("[25,26)", "27", False), ("25", "27", True),
            ("[25]", "25.0.1", False), ("[25]", "25.0.0", True),
            ("(25,26]", "25", False), ("(25,26]", "26", True),
            ("(,25],[27,)", "26", False), ("(,25],[27,)", "27", True),
            ("[25.0.2,25.0.4)", "25.0.1", False),
            ("[25.0.2,25.0.4)", "25.0.3+8-LTS", True),
            ("[8,9)", "1.8.0_402", True),
            ("[25.0.1-9,)", "25.0.1+8-LTS", False),
            ("[25.0.1-9,)", "25.0.1+10-LTS", True),
        ]
        for rule, version, expected in cases:
            with self.subTest(rule=rule, version=version):
                self.assertEqual(enforcer.accepts(rule, version), expected)

    def test_unsupported_range_fails_closed(self):
        for rule in ("${jdk.range}", "[25-ea,26)", "[25,26),", "(25)"):
            with self.subTest(rule=rule), self.assertRaises(ValueError):
                enforcer.intervals(rule)

    def test_detection_scope_properties_and_local_parent(self):
        plugin = """<plugin><artifactId>maven-enforcer-plugin</artifactId>
        <executions><execution><goals><goal>enforce</goal></goals>
        <configuration><rules><requireJavaVersion><version>${jdk.range}</version>
        </requireJavaVersion></rules></configuration></execution></executions></plugin>"""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "pom.xml").write_text("<project><properties><jdk.range>[25,26)</jdk.range></properties>"
                                          "<build><plugins>" + plugin + "</plugins></build></project>")
            child = root / "child"
            child.mkdir()
            (child / "pom.xml").write_text('<project xmlns="http://maven.apache.org/POM/4.0.0">'
                                          '<parent><relativePath>../pom.xml</relativePath></parent></project>')
            self.assertEqual(enforcer.rules(child / "pom.xml"), ["[25,26)"])
            # Unused management, inactive profiles and commented plugins are not executions.
            (root / "pom.xml").write_text("<project><build><pluginManagement><plugins>" + plugin +
                                          "</plugins></pluginManagement></build><profiles><profile><build><plugins>" +
                                          plugin + "</plugins></build></profile></profiles><!--" + plugin + "--></project>")
            self.assertEqual(enforcer.rules(root / "pom.xml"), [])
            disabled = plugin.replace("<rules>", "<skip>true</skip><rules>")
            (root / "pom.xml").write_text("<project><build><plugins>" + disabled + "</plugins></build></project>")
            self.assertEqual(enforcer.rules(root / "pom.xml"), [])
            (root / "pom.xml").write_text("<project><build><plugins>" + plugin + "</plugins></build></project>")
            with self.assertRaisesRegex(ValueError, "unresolved"):
                enforcer.rules(root / "pom.xml")


    def test_reactor_module_rules(self):
        def plugin(value):
            return """<build><plugins><plugin><artifactId>maven-enforcer-plugin</artifactId>
            <executions><execution><goals><goal>enforce</goal></goals><configuration>
            <rules><requireJavaVersion><version>""" + value + """</version></requireJavaVersion>
            </rules></configuration></execution></executions></plugin></plugins></build>"""

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            pom = root / "pom.xml"
            pom.write_text('<project xmlns="http://maven.apache.org/POM/4.0.0">'
                           '<properties><feature.module>feature</feature.module></properties>'
                           '<modules><module>${feature.module}</module><module>other.xml</module></modules>'
                           '<profiles><profile><modules><module>inactive-missing</module></modules></profile></profiles>'
                           '</project>')
            child = root / "feature"
            child.mkdir()
            (child / "pom.xml").write_text('<project><modules><module>nested</module></modules>' +
                                           plugin('[26,27)') + '</project>')
            nested = child / 'nested'
            nested.mkdir()
            (nested / 'pom.xml').write_text('<project>' + plugin('26') + '</project>')
            (root / 'other.xml').write_text('<project>' + plugin('[25,28)') + '</project>')
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                self.assertEqual(enforcer.main(['rules', str(root)]), 0)
            self.assertEqual(output.getvalue(), '[26,27)\n26\n[25,28)')
            ranges = enforcer.reactor_rules(pom)
            self.assertEqual(ranges, ['[26,27)', '26', '[25,28)'])
            self.assertFalse(all(enforcer.accepts(value, '25') for value in ranges))
            self.assertTrue(all(enforcer.accepts(value, '26') for value in ranges))
            self.assertFalse(all(enforcer.accepts(value, '27') for value in ranges))
            # A module cycle or unavailable declared POM must not drop constraints.
            (nested / 'pom.xml').write_text('<project><modules><module>../../pom.xml</module></modules></project>')
            with self.assertRaisesRegex(ValueError, 'cyclic reactor'):
                enforcer.reactor_rules(pom)
            (nested / 'pom.xml').unlink()
            with self.assertRaises(OSError):
                enforcer.reactor_rules(pom)


if __name__ == "__main__":
    unittest.main()
