#!/usr/bin/env python3
"""Read method-level metrics from a JaCoCo HTML class report.

CSV reports only contain class aggregates. JaCoCo class HTML pages retain each
method row, including instruction counters and complexity; this adapter keeps
the HTML fallback exact and refuses incomplete/ambiguous rows.
"""
import argparse
import html
import json
import re
import sys
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit


def text_value(value):
    return " ".join(html.unescape(value or "").split())


class CoverageTableParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.depth = 0
        self.in_table = False
        self.in_row = False
        self.in_cell = False
        self.rows = []
        self.row = []
        self.cell = None
        self.link = None

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "table":
            if not self.in_table and (attrs.get("id") == "coveragetable" or "coverage" in (attrs.get("class") or "").split()):
                self.in_table = True
                self.depth = 1
            elif self.in_table:
                self.depth += 1
            return
        if not self.in_table:
            return
        if tag == "tr":
            self.in_row = True
            self.row = []
        elif tag in ("td", "th") and self.in_row:
            self.in_cell = True
            self.cell = {"text": [], "links": [], "images": []}
        elif tag == "a" and self.in_cell:
            self.link = {"href": attrs.get("href", ""), "text": []}
        elif tag == "img" and self.in_cell:
            self.cell["images"].append({"src": attrs.get("src", ""), "title": attrs.get("title", ""), "alt": attrs.get("alt", "")})

    def handle_endtag(self, tag):
        if not self.in_table:
            return
        if tag == "a" and self.link is not None:
            self.link["text"] = text_value("".join(self.link["text"]))
            self.cell["links"].append(self.link)
            self.link = None
        elif tag in ("td", "th") and self.in_cell:
            self.cell["text"] = text_value("".join(self.cell["text"]))
            self.row.append(self.cell)
            self.cell = None
            self.in_cell = False
        elif tag == "tr" and self.in_row:
            if self.row:
                self.rows.append(self.row)
            self.row = []
            self.in_row = False
        elif tag == "table":
            self.depth -= 1
            if self.depth == 0:
                self.in_table = False

    def handle_data(self, data):
        if self.in_cell:
            self.cell["text"].append(data)
            if self.link is not None:
                self.link["text"].append(data)


def parse_count(value):
    match = re.search(r"\d+", value or "")
    return int(match.group()) if match else None


def instruction_counts(cell):
    missed = 0
    covered = 0
    found = False
    for image in cell.get("images", []):
        count = parse_count(image.get("title") or image.get("alt"))
        if count is None:
            continue
        found = True
        source = image.get("src", "").lower()
        if "redbar" in source:
            missed += count
        elif "greenbar" in source:
            covered += count
        else:
            found = False
            break
    return (missed, covered) if found else None


def method_link(row):
    if not row:
        return None
    for link in row[0].get("links", []):
        href = unquote(link.get("href", ""))
        parsed = urlsplit(href)
        if parsed.path.endswith(".java.html") and re.fullmatch(r"L\d+", parsed.fragment):
            return link, parsed
    return None


def source_roots(repo):
    return sorted(p for p in repo.rglob("src/main/java") if p.is_dir() and "target" not in p.parts)


def source_for_report_page(report_root, page, parsed_link, roots, repo_root):
    html_parts = page.relative_to(report_root).parent.parts
    source_name = Path(parsed_link.path).name.removesuffix(".html")
    # JaCoCo uses a single dot-separated directory for a Java package. An
    # aggregate report adds the Maven module name before that directory.
    package_name = html_parts[-1] if html_parts else ""
    module_name = html_parts[0] if report_root.name == "jacoco-aggregate" and len(html_parts) > 1 else ""
    report_module = None
    # Module-local reports live at <module>/target/site/jacoco[/aggregate].
    if len(report_root.parents) >= 3 and report_root.parent.name == "site" and report_root.parent.parent.name == "target":
        candidate = report_root.parent.parent.parent
        if candidate != repo_root:
            report_module = candidate
    matches = []
    for root in roots:
        for path in root.rglob(source_name):
            if not path.is_file():
                continue
            package_parts = path.relative_to(root).parent.parts
            package_matches = (".".join(package_parts) == package_name or
                               (len(package_parts) <= len(html_parts) and
                                (not package_parts or html_parts[-len(package_parts):] == package_parts)))
            if package_matches:
                module_root = root.parents[2]
                score = int(report_module is not None and module_root == report_module)
                score += int(module_name == module_root.name)
                matches.append((score, path))
    if not matches:
        raise ValueError(f"cannot map HTML source {source_name} in {page}")
    best = max(score for score, _ in matches)
    paths = sorted({path for score, path in matches if score == best})
    if len(paths) != 1:
        raise ValueError(f"ambiguous HTML source {source_name}: {', '.join(str(path) for path in paths)}")
    return paths[0]


def method_end_line(source, start_line):
    """Find a method body's closing line, ignoring braces in comments/literals."""
    state = "code"
    depth = 0
    body_started = False
    escaped = False
    line_number = 1
    i = 0
    while i < len(source):
        char = source[i]
        nxt = source[i + 1] if i + 1 < len(source) else ""
        if line_number < start_line:
            # Track lexical state before the method anchor so braces inside a
            # preceding comment or literal cannot corrupt the end-line scan.
            if state == "line_comment":
                if char == "\n":
                    state = "code"
            elif state == "block_comment":
                if char == "*" and nxt == "/":
                    state = "code"
                    i += 1
            elif state == "text_block":
                if source.startswith('"""', i):
                    state = "code"
                    i += 2
            elif state in ("string", "char"):
                if escaped:
                    escaped = False
                elif char == "\\":
                    escaped = True
                elif (state == "string" and char == '"') or (state == "char" and char == "'"):
                    state = "code"
            elif char == "/" and nxt == "/":
                state = "line_comment"
                i += 1
            elif char == "/" and nxt == "*":
                state = "block_comment"
                i += 1
            elif source.startswith('"""', i):
                state = "text_block"
                i += 2
            elif char == '"':
                state = "string"
            elif char == "'":
                state = "char"
            if char == "\n":
                line_number += 1
            i += 1
            continue
        if state == "line_comment":
            if char == "\n":
                state = "code"
        elif state == "block_comment":
            if char == "*" and nxt == "/":
                state = "code"
                i += 1
        elif state == "text_block":
            if source.startswith('"""', i):
                state = "code"
                i += 2
        elif state in ("string", "char"):
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif (state == "string" and char == '"') or (state == "char" and char == "'"):
                state = "code"
        else:
            if char == "/" and nxt == "/":
                state = "line_comment"
                i += 1
            elif char == "/" and nxt == "*":
                state = "block_comment"
                i += 1
            elif source.startswith('"""', i):
                state = "text_block"
                i += 2
            elif char == '"':
                state = "string"
            elif char == "'":
                state = "char"
            elif char == "{" and not body_started:
                body_started = True
                depth = 1
            elif char == "{" and body_started:
                depth += 1
            elif char == "}" and body_started:
                depth -= 1
                if depth == 0:
                    return line_number
            elif char == ";" and not body_started:
                return start_line
        if char == "\n":
            line_number += 1
        i += 1
    return start_line


def class_rows(page):
    parser = CoverageTableParser()
    parser.feed(page.read_text(encoding="utf-8", errors="replace"))
    for row in parser.rows:
        method = method_link(row)
        if method:
            yield row, method


def collect_entries(report_root, repo_root, changed_files=None):
    if changed_files is not None and not changed_files:
        return []
    roots = source_roots(repo_root)
    if not roots:
        raise ValueError(f"no production Java source roots found under {repo_root}")
    raw_entries = []
    errors = []
    for page in sorted(report_root.rglob("*.html")):
        if page.name.endswith(".java.html"):
            continue
        method_rows = []
        try:
            method_rows = list(class_rows(page))
            for row, (link, parsed_link) in method_rows:
                try:
                    source = source_for_report_page(report_root, page, parsed_link, roots, repo_root)
                except ValueError:
                    if changed_files is not None:
                        # report.py diagnoses changed files missing from output.
                        continue
                    raise
                if changed_files is not None and source.relative_to(repo_root).as_posix() not in changed_files:
                    continue
                if len(row) < 7:
                    raise ValueError(f"incomplete method row in {page}")
                counts = instruction_counts(row[1])
                complexity = parse_count(row[6]["text"])
                line_match = re.fullmatch(r"L(\d+)", parsed_link.fragment)
                if counts is None or complexity is None or line_match is None:
                    raise ValueError(f"method metrics are incomplete in {page}: {link['text']}")
                missed, covered = counts
                total = missed + covered
                if total == 0:
                    raise ValueError(f"method has no instruction count in {page}: {link['text']}")
                source_text = source.read_text(encoding="utf-8", errors="replace")
                start_line = int(line_match.group(1))
                end_line = method_end_line(source_text, start_line)
                cc = max(complexity, 1)
                coverage = covered / total
                crap = cc * cc * (1 - coverage) ** 3 + cc
                package = re.search(r"(?m)^\s*package\s+([\w.]+)\s*;", source_text)
                class_name = f"{package.group(1)}.{page.stem}" if package else page.stem
                raw_entries.append({
                    "method": link["text"],
                    "class": class_name,
                    "file": source.relative_to(repo_root).as_posix(),
                    "line": start_line,
                    "end_line": max(start_line, end_line),
                    "complexity": cc,
                    "coverage_percent": coverage * 100,
                    "crap": crap,
                    "status": "measured",
                })
        except OSError as exc:
            errors.append(str(exc))
        except ValueError as exc:
            # Package indexes and source pages are not method tables. Only
            # report failures from pages that actually contain method rows.
            if method_rows:
                errors.append(str(exc))
    if errors:
        raise ValueError("; ".join(errors[:8]))
    if not raw_entries and changed_files is None:
        raise ValueError(f"no method-level JaCoCo coverage tables found in {report_root}")
    return raw_entries


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--html-root", required=True)
    parser.add_argument("--repo-root", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--changes-file")
    args = parser.parse_args()
    repo = Path(args.repo_root).resolve()
    report_root = Path(args.html_root).resolve()
    try:
        changed_files = set(json.loads(Path(args.changes_file).read_text())["files"]) if args.changes_file else None
        entries = collect_entries(report_root, repo, changed_files)
    except (OSError, ValueError) as exc:
        print(f"Error: cannot read JaCoCo HTML method metrics: {exc}", file=sys.stderr)
        return 2
    Path(args.output).write_text(json.dumps({"entries": entries}, indent=2) + "\n")
    print(f"Read {len(entries)} Java methods from JaCoCo HTML: {report_root}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
