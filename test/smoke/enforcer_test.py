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


if __name__ == "__main__":
    unittest.main()
