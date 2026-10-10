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
    def test_focused_plan_keeps_production_suite_and_selects_boot_it(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = pathlib.Path(directory)
            for owner in ("client", "boot"):
                repo.joinpath(owner).mkdir()
                repo.joinpath(owner, "pom.xml").write_text("<project/>")
            it = repo / "boot/src/test/java/example/OwnersIT.java"
            it.parent.mkdir(parents=True)
            it.write_text("class OwnersIT {}")
            self.assertEqual(scope.focused_plan(repo, repo, "HEAD", [
                "client/src/main/java/example/Owner.java", "boot/src/test/java/example/OwnersIT.java"]),
                "boot\texample.OwnersIT\nclient\t*")

    def test_focused_helper_or_deleted_test_runs_entire_owner(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = pathlib.Path(directory)
            repo.joinpath("boot").mkdir()
            repo.joinpath("boot/pom.xml").write_text("<project/>")
            self.assertEqual(scope.focused_plan(repo, repo, "HEAD", ["boot/src/test/java/DeletedIT.java"]), "boot\t*")

    def test_focused_unknown_root_change_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = pathlib.Path(directory)
            with self.assertRaises(ValueError):
                scope.focused_plan(repo, repo, "HEAD", ["src/main/java/Owner.java"])

    def test_production_and_it_owner_without_aggregator(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = pathlib.Path(directory)
            self.assertEqual(scope.selection(repo, repo / "code", "HEAD", [
                "code/client/src/main/java/Owner.java", "code/client/src/test/java/OwnerTest.java",
                "code/boot/src/test/java/OwnerIT.java"]), "boot,client")

    def test_empty_diff_lines_do_not_become_unclassified_files(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = pathlib.Path(directory)
            self.assertEqual(scope.selection(repo, repo, 'HEAD', ['', '']), '')
            self.assertEqual(scope.focused_plan(repo, repo, 'HEAD', ['', '']), '')

    def test_unclassified_build_paths_require_broad_verification(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = pathlib.Path(directory)
            for path in ['.mvn/maven.config', '.mvn/extensions.xml', 'build.sh', 'code/build.sh']:
                with self.subTest(path=path):
                    self.assertEqual(scope.selection(repo, repo / 'code', 'HEAD', [path]), '.')
                    with self.assertRaises(ValueError):
                        scope.focused_plan(repo, repo / 'code', 'HEAD', [path])
            self.assertEqual(scope.selection(repo, repo / 'code', 'HEAD', ['README.md', 'docs/guide.md']), '')
            self.assertEqual(scope.selection(repo, repo / 'code', 'HEAD', ['code/client/src/main/resources/config.txt']), 'client')

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

    def test_inherited_version_bump_with_avro_resources_selects_boot(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = pathlib.Path(directory)
            base = repo / 'code'
            base.joinpath('boot').mkdir(parents=True)
            xml = '<project><artifactId>root</artifactId><properties><event.version>{}</event.version></properties></project>'
            base.joinpath('pom.xml').write_text(xml.format('3.0'))
            base.joinpath('boot/pom.xml').write_text('''<project><parent><artifactId>root</artifactId></parent>
                <dependencies><dependency><groupId>api</groupId><artifactId>event</artifactId>
                <version>${event.version}</version></dependency></dependencies></project>''')
            subprocess.run(['git', 'init', '-q', str(repo)], check=True)
            subprocess.run(['git', '-C', str(repo), 'add', '.'], check=True)
            subprocess.run(['git', '-C', str(repo), '-c', 'user.name=Test', '-c', 'user.email=test@example.com',
                            'commit', '-qm', 'base'], check=True)
            base.joinpath('pom.xml').write_text(xml.format('3.5.1'))
            self.assertEqual(scope.focused_plan(repo, base, 'HEAD', ['code/pom.xml',
                'code/boot/src/test/resources/compose/schema_registry/schemas/event/type.avsc']), 'boot\t*')

    def test_inherited_versions_reject_ambiguous_usage(self):
        xml = '<project><artifactId>root</artifactId><properties><event.version>{}</event.version></properties></project>'
        dependency = '<dependencies><dependency><version>${event.version}</version></dependency></dependencies>'
        cases = [
            '<profiles><profile>' + dependency + '</profile></profiles>',
            '<build><plugins><plugin><version>${event.version}</version></plugin></plugins></build>',
            '<properties><alias>${event.version}</alias></properties>',
            '<properties><event.version>9</event.version></properties>' + dependency,
            dependency.replace('${event.version}', '${event.version}-suffix'),
            '<parent><artifactId>other</artifactId></parent>' + dependency,
            '<parent><artifactId>root</artifactId><relativePath/></parent>' + dependency,
            '<parent><artifactId>root</artifactId><relativePath>../../pom.xml</relativePath></parent>' + dependency,
            '<configuration value="${event.version}"/>',
        ]
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            base.joinpath('boot').mkdir()
            for body in cases:
                with self.subTest(body=body):
                    if '<parent>' not in body:
                        body = '<parent><artifactId>root</artifactId></parent>' + body
                    base.joinpath('boot/pom.xml').write_text('<project>' + body + '</project>')
                    self.assertIsNone(scope.bump_consumers(base, scope.parse(xml.format('3')), scope.parse(xml.format('4'))))

    def test_unknown_impact_names_blocking_file(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = pathlib.Path(directory)
            with self.assertRaisesRegex(ValueError, r'in build.sh; use --exhaustive'):
                scope.focused_plan(repo, repo, 'HEAD', ['boot/src/test/resources/type.avsc', 'build.sh'])

    def test_inherited_version_selects_all_consumers_and_rejects_unused_bump(self):
        xml = '<project><artifactId>root</artifactId><properties><event.version>{}</event.version></properties></project>'
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            for owner in ('boot', 'client'):
                base.joinpath(owner).mkdir()
                base.joinpath(owner, 'pom.xml').write_text('''<project><parent><artifactId>root</artifactId></parent>
                    <dependencies><dependency><version>${event.version}</version></dependency>
                    <dependency><version>${event.version}</version></dependency></dependencies></project>''')
            self.assertEqual(scope.bump_consumers(base, scope.parse(xml.format('3')), scope.parse(xml.format('4'))), {'boot', 'client'})
            extra = xml.replace('</properties>', '<unused.version>1</unused.version></properties>')
            self.assertIsNone(scope.bump_consumers(base, scope.parse(extra.format('3')),
                scope.parse(extra.format('4').replace('<unused.version>1', '<unused.version>2'))))

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
