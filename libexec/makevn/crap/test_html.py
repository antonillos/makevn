import tempfile
import unittest
from pathlib import Path

import jacoco_html as crap_html


class JacocoHtmlReaderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.repo = Path(self.temp.name)
        self.module = self.repo / "module-a"
        self.source = self.module / "src/main/java/example/Foo.java"
        self.source.parent.mkdir(parents=True)
        self.source.write_text(
            "package example;\n"
            "class Foo {\n"
            "  void risky() {\n"
            "    if (true) { work(); }\n"
            "  }\n"
            "  void work() {}\n"
            "}\n"
        )
        self.report = self.module / "target/site/jacoco"
        (self.report / "example").mkdir(parents=True)
        self.page = self.report / "example/Foo.html"
        self.page.write_text(
            '<html><table id="coveragetable"><tbody><tr>'
            '<td><a href="Foo.java.html#L3">risky()</a></td>'
            '<td><img src="../jacoco-resources/redbar.gif" title="2 of 5 instructions missed"/>'
            '<img src="../jacoco-resources/greenbar.gif" title="3 of 5 instructions covered"/></td>'
            '<td>60%</td><td></td><td>100%</td><td>0</td><td>4</td>'
            '<td>0</td><td>3</td><td>0</td><td>1</td></tr></tbody></table></html>'
        )

    def tearDown(self):
        self.temp.cleanup()

    def test_reads_method_level_counts_complexity_and_source_location(self):
        entries = crap_html.collect_entries(self.report, self.repo)
        self.assertEqual(len(entries), 1)
        entry = entries[0]
        self.assertEqual(entry["method"], "risky()")
        self.assertEqual(entry["file"], "module-a/src/main/java/example/Foo.java")
        self.assertEqual(entry["line"], 3)
        self.assertEqual(entry["end_line"], 5)
        self.assertEqual(entry["complexity"], 4)
        self.assertEqual(entry["coverage_percent"], 60)
        self.assertAlmostEqual(entry["crap"], 5.024)

    def test_rejects_method_rows_without_exact_counter_details(self):
        self.page.write_text(
            '<table id="coveragetable"><tr><td><a href="Foo.java.html#L3">risky()</a></td>'
            '<td>60%</td><td></td><td></td><td></td><td>0</td><td>4</td></tr></table>'
        )
        with self.assertRaisesRegex(ValueError, "metrics are incomplete"):
            crap_html.collect_entries(self.report, self.repo)

    def test_scans_braces_after_multiline_comments_before_anchor(self):
        self.source.write_text(
            "package example;\n/* }\n   { */\nclass Foo {\n"
            "  void risky() {\n    if (true) { work(); }\n  }\n}\n"
        )
        self.page.write_text(self.page.read_text().replace("#L3", "#L5"))
        entries = crap_html.collect_entries(self.report, self.repo)
        self.assertEqual(entries[0]["end_line"], 7)

    def test_expands_executable_anchor_to_full_method_range(self):
        self.source.write_text(
            "package example;\nclass Foo {\n"
            "  void risky(\n      int value) {\n"
            "    if (value > 0) {\n      work();\n    }\n"
            "    work();\n  }\n}\n"
        )
        self.page.write_text(self.page.read_text().replace("risky()", "risky(int)").replace("#L3", "#L6"))
        entries = crap_html.collect_entries(self.report, self.repo)
        self.assertEqual((entries[0]["line"], entries[0]["end_line"]), (3, 9))

    def test_matches_reported_method_when_anchor_is_inside_nested_method(self):
        self.source.write_text(
            "package example;\nclass Foo {\n"
            "  void risky() {\n"
            "    Runnable task = new Runnable() { public void run() {} };\n"
            "    work();\n  }\n  void work() {}\n}\n"
        )
        self.page.write_text(self.page.read_text().replace("#L3", "#L4"))
        entries = crap_html.collect_entries(self.report, self.repo)
        self.assertEqual((entries[0]["line"], entries[0]["end_line"]), (3, 6))

    def test_skips_implicit_default_constructor_row(self):
        document = self.page.read_text()
        row = document[document.index("<tr>"):document.index("</tr>") + len("</tr>")]
        constructor = row.replace("risky()", "Foo()").replace("#L3", "#L2")
        self.page.write_text(document.replace("</tbody>", constructor + "</tbody>"))
        entries = crap_html.collect_entries(self.report, self.repo)
        self.assertEqual([entry["method"] for entry in entries], ["risky()"])

    def test_aggregate_report_maps_dot_separated_package_and_module(self):
        aggregate = self.repo / "jacoco-report-aggregate/target/site/jacoco-aggregate"
        package = aggregate / "module-a/com.example"
        package.mkdir(parents=True)
        (package / "Foo.html").write_text(self.page.read_text())
        source = self.module / "src/main/java/com/example/Foo.java"
        source.parent.mkdir(parents=True)
        source.write_text(self.source.read_text().replace("package example;", "package com.example;"))
        other = self.repo / "module-b/src/main/java/com/example/Foo.java"
        other.parent.mkdir(parents=True)
        other.write_text(source.read_text())
        entries = crap_html.collect_entries(aggregate, self.repo)
        self.assertEqual(entries[0]["file"], "module-a/src/main/java/com/example/Foo.java")

    def test_changes_ignore_unrelated_unmapped_report_pages(self):
        unrelated = self.report / "unmapped"
        unrelated.mkdir()
        (unrelated / "Missing.html").write_text(self.page.read_text().replace("Foo.java.html", "Missing.java.html"))
        self.assertEqual(crap_html.collect_entries(self.report, self.repo, set()), [])
        entries = crap_html.collect_entries(self.report, self.repo, {"module-a/src/main/java/example/Foo.java"})
        self.assertEqual(len(entries), 1)


if __name__ == "__main__":
    unittest.main()
