#!/usr/bin/env python3
"""Safety regressions for the one-way migration (no Make executable required)."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
import sys
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("legacy_make", ROOT / "libexec/makevn/common/legacy_make.py")
migration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(migration)
TEMPLATE = (ROOT / "test/smoke/fixtures/legacy-makevn.mk").read_bytes()


class RetirementTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.repo = Path(self.temporary.name)
        self.state = self.repo / ".makevn"
        self.state.mkdir()
        self.custom = b"custom:\n\t@echo untouched\n\n"

    def seed(self, managed="Makefile", generated=""):
        values = {"managed_makefile": managed, "generated_root_makefile": generated}
        (self.state / "manifest").write_text("makevn_version=old\n" + "".join(f"{k}={v}\n" for k, v in values.items()))
        (self.state / "state.json").write_text(json.dumps(values))
        (self.state / "makevn.mk").write_bytes(TEMPLATE)
        name = managed or generated
        if name:
            (self.repo / name).write_bytes(self.custom + migration.BLOCK if managed else migration.BOOTSTRAP)

    def snapshot(self):
        return {str(p.relative_to(self.repo)): p.read_bytes() for p in self.repo.rglob("*") if p.is_file()}

    def assert_blocked(self):
        before = self.snapshot()
        with self.assertRaises(ValueError):
            migration.retire(self.repo, False)
        self.assertEqual(self.snapshot(), before)

    def test_existing_makefiles_preserve_custom_bytes_and_permissions(self):
        for name in ("Makefile", "GNUmakefile"):
            with self.subTest(name=name):
                self.seed(name)
                path = self.repo / name
                path.chmod(0o640)
                migration.retire(self.repo, False)
                self.assertEqual(path.read_bytes(), self.custom)
                self.assertEqual(path.stat().st_mode & 0o777, 0o640)
                self.assertFalse((self.state / "makevn.mk").exists())
                migration.retire(self.repo, False)

    def test_bootstrap_dry_run_then_idempotent_retirement(self):
        self.seed("", "Makefile")
        before = self.snapshot()
        migration.retire(self.repo, True)
        self.assertEqual(self.snapshot(), before)
        migration.retire(self.repo, False)
        self.assertFalse((self.repo / "Makefile").exists())
        migration.retire(self.repo, False)

    def test_preflight_modified_template_before_root_edit(self):
        self.seed()
        with (self.state / "makevn.mk").open("ab") as stream:
            stream.write(b"custom:\n\t@echo do not delete\n")
        self.assert_blocked()

    def test_modified_bootstrap_blocked(self):
        self.seed("", "Makefile")
        (self.repo / "Makefile").write_bytes(migration.BOOTSTRAP + self.custom)
        self.assert_blocked()

    def test_modified_incomplete_duplicate_and_untracked_blocks(self):
        for content in (migration.BEGIN + self.custom + migration.END,
                        migration.BEGIN, migration.END, migration.BLOCK * 2,
                        migration.BLOCK + b"include .makevn/makevn.mk\n"):
            self.seed()
            (self.repo / "Makefile").write_bytes(self.custom + content)
            self.assert_blocked()
        self.seed("")
        (self.repo / "Makefile").write_bytes(migration.BLOCK)
        self.assert_blocked()

    def test_unsafe_manifest_fields(self):
        for field, value in (("managed_makefile", "../outside"), ("generated_root_makefile", "/tmp/outside"),
                             ("managed_makefile", "sub/Makefile"), ("generated_root_makefile", "GNUmakefile")):
            self.seed()
            values = {"managed_makefile": "", "generated_root_makefile": "", field: value}
            (self.state / "manifest").write_text("".join(f"{k}={v}\n" for k, v in values.items()))
            (self.state / "state.json").write_text(json.dumps(values))
            self.assert_blocked()

    def test_symlinks_and_inconsistent_records(self):
        self.seed()
        (self.state / "state.json").write_text('{"managed_makefile":"GNUmakefile"}')
        self.assert_blocked()
        for name in ("Makefile", ".makevn/makevn.mk", ".makevn/manifest", ".makevn/state.json"):
            self.seed()
            path = self.repo / name
            target = self.repo / "outside"
            target.write_bytes(path.read_bytes())
            path.unlink()
            path.symlink_to(target)
            self.assert_blocked()
            path.unlink()

    def test_missing_manifest_uses_state_ownership(self):
        self.seed()
        (self.state / "manifest").unlink()
        migration.retire(self.repo, False)
        self.assertEqual((self.repo / "Makefile").read_bytes(), self.custom)

    def test_orphan_known_template_and_missing_root_are_safe(self):
        self.seed()
        (self.repo / "Makefile").unlink()
        migration.retire(self.repo, False)
        self.seed("")
        migration.retire(self.repo, False)

    def test_unrelated_makefiles_and_symlinks_untouched(self):
        (self.repo / "Makefile").write_bytes(self.custom)
        (self.repo / "GNUmakefile").symlink_to(self.repo / "Makefile")
        migration.retire(self.repo, False)
        self.assertEqual((self.repo / "Makefile").read_bytes(), self.custom)
        self.assertTrue((self.repo / "GNUmakefile").is_symlink())

    def test_state_directory_symlink_rejected(self):
        self.state.rmdir()
        target = self.repo / "outside"
        target.mkdir()
        self.state.symlink_to(target, target_is_directory=True)
        self.assert_blocked()


if __name__ == "__main__":
    unittest.main()
