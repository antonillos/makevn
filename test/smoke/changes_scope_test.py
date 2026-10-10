"""Static selection regressions; no Maven/network required."""
import importlib.util
import pathlib
import tempfile
import unittest
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("scope", ROOT / "libexec/makevn/common/changes_scope.py")
scope = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scope)


class ScopeTests(unittest.TestCase):
    def test_production_and_it_owner_without_aggregator(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = pathlib.Path(directory)
            self.assertEqual(scope.selection(repo, repo / "code", "HEAD", [
                "code/client/src/main/java/Owner.java", "code/client/src/test/java/OwnerTest.java",
                "code/boot/src/test/java/OwnerIT.java"]), "boot,client")

    def test_root_java_requires_full_reactor(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = pathlib.Path(directory)
            self.assertEqual(scope.selection(repo, repo, "HEAD", ["src/main/java/Owner.java"]), ".")

    def test_managed_bump_finds_direct_consumer(self):
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            client = base / "client"
            client.mkdir()
            client.joinpath("pom.xml").write_text('''<project><parent><artifactId>root</artifactId></parent>
              <dependencies><dependency><groupId>api</groupId><artifactId>categories</artifactId>
              </dependency></dependencies></project>''')
            xml = '''<project><artifactId>root</artifactId><properties><api.version>{}</api.version></properties>
              <dependencyManagement><dependencies><dependency><groupId>api</groupId><artifactId>categories</artifactId>
              <version>${{api.version}}</version></dependency></dependencies></dependencyManagement></project>'''
            self.assertEqual(scope.bump_consumers(base, scope.parse(xml.format("3.5")), scope.parse(xml.format("4.2"))), {"client"})

    def test_non_property_change_is_not_narrowed(self):
        self.assertIsNone(scope.property_bumps(scope.parse('<project><properties><v>1</v></properties></project>'),
                                              scope.parse('<project><properties><v>2</v></properties><modules/></project>')))

    def test_pom_only_unknown_change_requires_full_reactor(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = pathlib.Path(directory)
            pom = repo / "pom.xml"
            pom.write_text('<project><properties><api.version>1</api.version></properties></project>')
            subprocess.run(["git", "init", "-q", str(repo)], check=True)
            subprocess.run(["git", "-C", str(repo), "add", "."], check=True)
            subprocess.run(["git", "-C", str(repo), "-c", "user.name=Test", "-c", "user.email=test@example.com",
                            "commit", "-qm", "base"], check=True)
            pom.write_text('<project><properties><api.version>2</api.version></properties></project>')
            self.assertEqual(scope.selection(repo, repo, "HEAD", ["pom.xml"]), ".")

    def test_namespace_and_formatting_are_accepted(self):
        self.assertEqual(scope.property_bumps(scope.parse('<project xmlns="urn:maven"><properties><api.version>1</api.version></properties></project>'),
                                              scope.parse('<project xmlns="urn:maven">\n <properties><api.version>2</api.version></properties></project>')), {"api.version"})


if __name__ == "__main__":
    unittest.main()
