import importlib.util
import os
import pathlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("reports", ROOT / "libexec/makevn/common/selected_test_reports.py")
reports = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reports)


class ReportTests(unittest.TestCase):
    def test_it_is_not_also_sent_to_surefire(self):
        flags = reports.selection_flags(pathlib.Path("/nonexistent"), ["example.OwnerIT"])
        self.assertEqual(flags[:2], ["-Dtest=!%regex[.*]", "-Dit.test=example.OwnerIT"])

    def test_mixed_unit_and_it_have_separate_selectors(self):
        flags = reports.selection_flags(pathlib.Path("/nonexistent"), ["example.OwnerTest", "example.OwnerIT"])
        self.assertEqual(flags[:2], ["-Dtest=example.OwnerTest", "-Dit.test=example.OwnerIT"])

    def test_requires_fresh_non_skipped_case_for_every_class(self):
        with tempfile.TemporaryDirectory() as directory:
            module = pathlib.Path(directory)
            stamp = module / "stamp"
            stamp.touch()
            target = module / "target/failsafe-reports"
            target.mkdir(parents=True)
            report = target / "TEST-example.OwnerIT.xml"
            report.write_text('<testsuite><testcase classname="example.OwnerIT" name="test"/></testsuite>')
            self.assertEqual(reports.missing_tests(module, ["example.OwnerIT"], stamp), [])
            unit_target = module / "target/surefire-reports"
            unit_target.mkdir()
            unit_target.joinpath("TEST-example.OtherIT.xml").write_text('<testsuite><testcase classname="example.OtherIT" name="test"/></testsuite>')
            self.assertEqual(reports.missing_tests(module, ["example.OwnerIT", "example.OtherIT"], stamp), ["example.OtherIT"])
            report.write_text('<testsuite><testcase classname="example.OwnerIT" name="test"><skipped/></testcase></testsuite>')
            self.assertEqual(reports.missing_tests(module, ["example.OwnerIT"], stamp), ["example.OwnerIT"])
            report.write_text('<testsuite><testcase classname="example.OwnerIT" name="test"/></testsuite>')
            os.utime(report, ns=(stamp.stat().st_mtime_ns - 1_000_000_000,) * 2)
            self.assertEqual(reports.missing_tests(module, ["example.OwnerIT"], stamp), ["example.OwnerIT"])


if __name__ == "__main__":
    unittest.main()
