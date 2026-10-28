import contextlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "libexec/makevn/common" / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


inspection = load("maven_inspection")
project = load("maven_project")


def pom(rule="[3.9.14,3.10.0)"):
    return """<project xmlns="http://maven.apache.org/POM/4.0.0"><build><plugins>
    <plugin><artifactId>maven-enforcer-plugin</artifactId><executions>
    <execution><goals><goal>enforce</goal></goals><configuration><rules>
    <requireMavenVersion><version>""" + rule + """</version></requireMavenVersion>
    </rules></configuration></execution>
    <execution><goals><goal>enforce</goal></goals><configuration>
    <skip>${skipSnapshots}</skip><rules><requireSnapshotVersion/></rules>
    </configuration></execution></executions></plugin></plugins></build></project>"""


class MavenInspectionTests(unittest.TestCase):
    def test_profile_module_path_is_deferred_without_probing_unconstrained_build(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "pom.xml").write_text('''<project><modules><module>${module.dir}</module></modules>
            <profiles><profile><id>default</id><activation><activeByDefault>true</activeByDefault></activation>
            <properties><module.dir>child</module.dir></properties></profile></profiles></project>''')
            (root / "child").mkdir()
            (root / "child/pom.xml").write_text("<project/>")
            message = inspection.inspect("missing-maven", root, root, "", True)
            self.assertIn("deferred to Maven", message)

    def test_deferred_module_does_not_hide_known_maven_constraints(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "pom.xml").write_text(pom().replace("<build>",
                "<modules><module>${module.dir}</module><module>child</module></modules><build>", 1))
            (root / "child").mkdir()
            (root / "child/pom.xml").write_text(pom("[3.9.15,4)"))
            executable = root / "mvn"
            executable.write_text("#!/bin/sh\necho 'Apache Maven 3.9.14'\n")
            executable.chmod(0o755)
            with self.assertRaisesRegex(ValueError, "does not satisfy"):
                inspection.inspect(str(executable), root, root, "", True)
            executable.write_text("#!/bin/sh\necho 'Apache Maven 3.9.15'\n")
            self.assertIn("deferred to Maven", inspection.inspect(str(executable), root, root, "", True))
            (root / "child/pom.xml").write_text(pom("${unknown.range}"))
            with self.assertRaisesRegex(ValueError, "unresolved Enforcer property"):
                inspection.inspect(str(executable), root, root, "", True)

    def test_execution_version_overrides_shared_plugin_rule(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "pom.xml").write_text('''<project><build><plugins><plugin>
            <artifactId>maven-enforcer-plugin</artifactId><configuration><rules>
            <requireMavenVersion><version>[3.8,3.9)</version></requireMavenVersion>
            </rules></configuration><executions><execution><goals><goal>enforce</goal></goals>
            <configuration><rules><requireMavenVersion><version>[3.9,4)</version>
            </requireMavenVersion></rules></configuration></execution></executions>
            </plugin></plugins></build></project>''')
            executable = root / "mvn"
            executable.write_text("#!/bin/sh\necho 'Apache Maven 3.9.10'\n")
            executable.chmod(0o755)
            self.assertEqual(inspection.reactor_rules(root / "pom.xml", rule_name="requireMavenVersion"),
                             ["[3.9,4)"])
            self.assertIn("compatible", inspection.inspect(str(executable), root, root, "", True))

    def test_nested_aggregator_and_ambiguity(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            aggregate = root / "aidev/work/compiler/code"
            child = aggregate / "apifirst-compiler-event"
            child.mkdir(parents=True)
            (aggregate / "pom.xml").write_text(pom())
            (child / "pom.xml").write_text("<project/>")
            self.assertEqual(project.discover(root), aggregate)
            other = root / "other"
            other.mkdir()
            (other / "pom.xml").write_text("<project/>")
            with self.assertRaisesRegex(ValueError, "Ambiguous Maven projects"):
                project.discover(root)
            (root / "pom.xml").write_text("<project/>")
            self.assertEqual(project.discover(root), root)

    def test_generated_and_state_poms_are_ignored(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("target", "node_modules", ".git", ".makevn"):
                (root / name).mkdir()
                (root / name / "pom.xml").write_text("<project/>")
            self.assertIsNone(project.discover(root))

    def test_selected_maven_version_is_checked(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "pom.xml").write_text(pom())
            executable = root / "mvn"
            executable.touch()
            executable.chmod(0o755)
            for version, accepted in (("3.9.14", True), ("3.9.15", True), ("3.9.9", False),
                                      ("3.10.0", False), ("4.0.0", False), ("4.0.0-rc-4", False)):
                executable.write_text("#!/bin/sh\nprintf 'Apache Maven " + version + "\\n'\n")
                with self.subTest(version=version):
                    if accepted:
                        self.assertIn("compatible", inspection.inspect(str(executable), root, root, "", True))
                    else:
                        with self.assertRaises(ValueError):
                            inspection.inspect(str(executable), root, root, "", True)

    def test_wrapper_doctor_does_not_execute_or_download(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "pom.xml").write_text(pom())
            wrapper = root / "mvnw"
            wrapper.write_text("#!/bin/sh\ntouch 'executed'\necho 'Apache Maven 3.9.9'\n")
            wrapper.chmod(0o755)
            properties = root / ".mvn/wrapper/maven-wrapper.properties"
            properties.parent.mkdir(parents=True)
            properties.write_text("distributionUrl=https://example.test/apache-maven-3.9.14-bin.zip\n")
            self.assertIn("runtime not probed", inspection.inspect(str(wrapper), root, root, ""))
            self.assertFalse((root / "executed").exists())
            with self.assertRaisesRegex(ValueError, "does not satisfy"):
                inspection.inspect(str(wrapper), root, root, "", True)
            self.assertTrue((root / "executed").exists())

    def test_unresolved_maven_property_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "pom.xml").write_text(pom("${maven.range}"))
            output = io.StringIO()
            with contextlib.redirect_stderr(output):
                self.assertEqual(inspection.main(["check", "missing-maven", str(root), str(root), ""]), 1)
            self.assertIn("unresolved Enforcer property", output.getvalue())

    def test_maven_ranges_do_not_use_java_eight_shorthand(self):
        self.assertTrue(inspection.accepts("[8,9)", "8.0.1", java=False))
        self.assertFalse(inspection.accepts("[8,9)", "1.8.0", java=False))


if __name__ == "__main__":
    unittest.main()
