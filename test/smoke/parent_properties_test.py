import importlib.util
import io
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import urllib.error

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("enforcer", ROOT / "libexec/makevn/jdk/enforcer.py")
enforcer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(enforcer)
import parent_properties as parents


class ParentPropertiesTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.environment = patch.dict(os.environ, {"HOME": str(self.root), "XDG_CACHE_HOME": str(self.root / "cache")})
        self.environment.start()
        self.addCleanup(self.environment.stop)
        parents.published_model.cache_clear()
        self.addCleanup(parents.published_model.cache_clear)
        self.pom = self.root / "pom.xml"
        self.pom.write_text('''<project><parent><groupId>org.example</groupId>
        <artifactId>starter-parent</artifactId><version>1.0</version><relativePath/></parent>
        <build><plugins><plugin><artifactId>maven-enforcer-plugin</artifactId><executions>
        <execution><goals><goal>enforce</goal></goals><configuration><rules><requireJavaVersion>
        <version>[${java.version},)</version></requireJavaVersion></rules></configuration></execution>
        </executions></plugin></plugins></build></project>''')

    def parent(self, repository, artifact="starter-parent", content="<java.version>17</java.version>"):
        path = repository / f"org/example/{artifact}/1.0/{artifact}-1.0.pom"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f"<project><properties>{content}</properties></project>")
        return path

    def test_cached_parent_and_local_override(self):
        self.parent(self.root / ".m2/repository")
        with patch.object(parents.urllib.request, "urlopen") as download:
            self.assertEqual(enforcer.reactor_rules(self.pom), ["[17,)"])
            self.assertFalse(enforcer.accepts(enforcer.rules(self.pom)[0], "11"))
            self.assertTrue(enforcer.accepts(enforcer.rules(self.pom)[0], "25"))
            self.assertEqual(enforcer.rules(self.pom, user_properties={"java.version": "21"}), ["[21,)"])
            self.pom.write_text(self.pom.read_text().replace("<build>",
                "<properties><java.version>25</java.version></properties><build>"))
            self.assertEqual(enforcer.rules(self.pom), ["[25,)"])
            download.assert_not_called()

    def test_central_parent_chain_and_persistent_cache(self):
        parent = b'''<project xmlns="http://maven.apache.org/POM/4.0.0"><parent>
        <groupId>org.example</groupId><artifactId>base</artifactId><version>1.0</version></parent>
        <properties><java.version>${baseline}</java.version></properties></project>'''
        base = b"<project><properties><baseline>17</baseline></properties></project>"
        with patch.object(parents.urllib.request, "urlopen", side_effect=[io.BytesIO(parent), io.BytesIO(base)]) as download:
            self.assertEqual(enforcer.reactor_rules(self.pom), ["[17,)"])
            self.assertEqual(download.call_count, 2)
            self.assertEqual(download.call_args_list[0].kwargs, {"timeout": 5})
        parents.published_model.cache_clear()
        with patch.object(parents.urllib.request, "urlopen") as download:
            self.assertEqual(enforcer.rules(self.pom), ["[17,)"])
            download.assert_not_called()

    def test_custom_local_repository_and_mirror(self):
        settings = self.root / ".m2/settings.xml"
        settings.parent.mkdir()
        settings.write_text('''<settings><localRepository>${user.home}/artifacts</localRepository>
        <mirrors><mirror><id>company</id><mirrorOf>*</mirrorOf></mirror></mirrors></settings>''')
        self.parent(self.root / "artifacts")
        with patch.object(parents.urllib.request, "urlopen") as download:
            self.assertEqual(enforcer.rules(self.pom), ["[17,)"])
            parents.published_model.cache_clear()
            self.parent(self.root / "artifacts").unlink()
            with self.assertRaisesRegex(ValueError, "offline/mirrored Maven settings"):
                enforcer.rules(self.pom)
            download.assert_not_called()

    def test_failure_does_not_accept_unknown_java_requirement(self):
        with patch.object(parents.urllib.request, "urlopen", side_effect=urllib.error.URLError("unavailable")):
            with self.assertRaisesRegex(ValueError, "Cannot inspect parent POM"):
                enforcer.rules(self.pom)

    def test_offline_metadata_must_be_cached_in_maven_repository(self):
        settings = self.root / ".m2/settings.xml"
        settings.parent.mkdir()
        settings.write_text("<settings><offline>true</offline></settings>")
        with patch.object(parents.urllib.request, "urlopen") as download:
            with self.assertRaisesRegex(ValueError, "offline/mirrored Maven settings"):
                enforcer.rules(self.pom)
            self.parent(self.root / ".m2/repository")
            self.assertEqual(enforcer.rules(self.pom), ["[17,)"])
            download.assert_not_called()

    def test_oversized_or_invalid_metadata_is_not_cached(self):
        for data, message in ((b"x" * 2_000_001, "size limit"), (b"not xml", "Cannot inspect parent POM")):
            with self.subTest(message=message):
                with patch.object(parents.urllib.request, "urlopen", return_value=io.BytesIO(data)):
                    with self.assertRaisesRegex(ValueError, message):
                        enforcer.rules(self.pom)
                self.assertFalse((self.root / "cache").exists())

    def test_cycles_and_nonliteral_coordinates_fail_closed(self):
        path = self.parent(self.root / ".m2/repository")
        path.write_text(self.pom.read_text())
        with self.assertRaisesRegex(ValueError, "Cyclic"):
            enforcer.rules(self.pom)
        self.pom.write_text(self.pom.read_text().replace("<version>1.0</version>", "<version>${revision}</version>"))
        with self.assertRaisesRegex(ValueError, "nonliteral coordinates"):
            enforcer.rules(self.pom)


if __name__ == "__main__":
    unittest.main()
