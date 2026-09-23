#!/usr/bin/env python3
import argparse
import json
import math
import sys
from pathlib import Path
from xml.etree import ElementTree


def arguments():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", action="append", required=True)
    parser.add_argument("--jacoco-xml", action="append")
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--threshold", type=float, default=8.0)
    parser.add_argument("--max-warnings", type=int)
    parser.add_argument("--changes-file")
    parser.add_argument("--repo-root")
    parser.add_argument("--source-root", action="append")
    return parser.parse_args()


def normalize(entry, threshold):
    class_name = entry.get("class") or ""
    method = entry.get("method") or entry.get("function") or "<unknown>"
    symbol = f"{class_name}#{method}" if class_name else method
    line = entry.get("line", 1)
    end_line = entry.get("end_line") or line
    crap = entry.get("crap")
    return {
        "language": "java",
        "file": entry.get("file", ""),
        "line": line,
        "end_line": end_line,
        "range": {"start_line": line, "end_line": end_line},
        "symbol": symbol,
        "complexity": entry.get("complexity", entry.get("cyclomatic")),
        "coverage_percent": entry.get("coverage_percent", entry.get("coverage")),
        "crap": crap,
        "status": entry.get("status", "measured" if crap is not None else "missing-coverage"),
        "recommendation": "reduce complexity or add focused tests" if crap is not None and crap > threshold else "none",
    }


def score(value):
    return "N/A" if value is None else f"{value:.2f}"


def changed_path(entry, source_root, repo_root, paths):
    raw = Path(entry["file"])
    candidate = (Path(source_root) / raw).resolve()
    try:
        relative = candidate.relative_to(repo_root).as_posix()
        if relative in paths:
            return relative
    except ValueError:
        pass
    suffix = "/" + raw.as_posix().lstrip("/")
    matches = [path for path in paths if ("/" + path).endswith(suffix)]
    if len(matches) > 1:
        raise ValueError(f"ambiguous changed Java path {raw}: {', '.join(matches)}")
    return matches[0] if matches else None


def main():
    args = arguments()
    if not math.isfinite(args.threshold) or args.threshold < 0 or args.max_warnings is not None and args.max_warnings < 0:
        return 2
    if args.jacoco_xml and len(args.jacoco_xml) != len(args.input):
        print("Error: each crap4java input must have a matching JaCoCo XML.", file=sys.stderr)
        return 2
    if args.changes_file and (not args.repo_root or not args.source_root or len(args.source_root) != len(args.input)):
        print("Error: changed CRAP requires a repository and one source root per analyzer report.", file=sys.stderr)
        return 2
    entries = []
    coverage_gaps = []
    try:
        changes = json.loads(Path(args.changes_file).read_text()) if args.changes_file else None
        changed_files = changes["files"] if changes else {}
        repo_root = Path(args.repo_root).resolve() if changes else None
        matched_files = set()
        for index, source in enumerate(args.input):
            payload = json.loads(Path(source).read_text())
            if not isinstance(payload.get("entries"), list):
                raise ValueError(f"missing entries array: {source}")
            selected = []
            for entry in payload["entries"]:
                if changes:
                    path = changed_path(entry, args.source_root[index], repo_root, changed_files)
                    if path is None:
                        continue
                    matched_files.add(path)
                    start = int(entry.get("line") or 1)
                    end = int(entry.get("end_line") or start)
                    if not any(a <= end and b >= start for a, b in changed_files[path]):
                        continue
                    entry = dict(entry, file=path)
                selected.append(entry)
            if args.jacoco_xml:
                xml_path = args.jacoco_xml[index]
                xml_classes = {
                    node.get("name", "").replace("/", ".")
                    for node in ElementTree.parse(xml_path).iter("class")
                }
                for entry in selected:
                    if entry.get("crap") is not None:
                        continue
                    class_name = entry.get("class") or ""
                    coverage_gaps.append({
                        "reason": "class absent from JaCoCo XML" if class_name not in xml_classes else "method not matched in JaCoCo XML",
                        "class": class_name,
                        "method": entry.get("method") or entry.get("function") or "<unknown>",
                        "file": entry.get("file") or "",
                        "line": entry.get("line") or 1,
                        "jacoco_xml": xml_path,
                    })
            entries.extend(normalize(entry, args.threshold) for entry in selected)
        if changes:
            unmatched_files = set(changed_files) - matched_files
            if unmatched_files:
                raise ValueError("changed Java source absent from analyzer output (stale coverage or uncompiled source): " + ", ".join(sorted(unmatched_files)))
    except (OSError, ElementTree.ParseError, json.JSONDecodeError, ValueError) as exc:
        print(f"Error: invalid crap4java report: {exc}", file=sys.stderr)
        return 2
    if not entries and not args.changes_file:
        print("Error: CRAP report contains no measured Java methods.", file=sys.stderr)
        return 2
    seen_methods = set()
    for entry in entries:
        identity = (entry["file"], entry["line"], entry["symbol"])
        if identity in seen_methods:
            print(
                f"Error: overlapping JaCoCo reports contain duplicate Java method {entry['symbol']} "
                f"at {entry['file']}:{entry['line']}; use a merged report or pass --jacoco-xml.",
                file=sys.stderr,
            )
            return 2
        seen_methods.add(identity)
    missing_coverage = sum(entry["crap"] is None for entry in entries)
    if missing_coverage:
        print(f"Error: CRAP report contains {missing_coverage} Java method(s) without coverage.", file=sys.stderr)
        if changes:
            for gap in coverage_gaps:
                print(f"Error: {gap['file']}:{gap['line']} {gap['class']}#{gap['method']}: {gap['reason']} [XML: {gap['jacoco_xml']}]", file=sys.stderr)
        if coverage_gaps:
            absent = sum(gap["reason"] == "class absent from JaCoCo XML" for gap in coverage_gaps)
            unmatched = len(coverage_gaps) - absent
            output_dir = Path(args.output_dir)
            output_dir.mkdir(parents=True, exist_ok=True)
            gap_report = output_dir / "coverage-gaps.txt"
            lines = [
                f"Java methods without coverage: {missing_coverage}",
                f"Classes absent from JaCoCo XML: {absent} method(s)",
                f"Methods not matched in present classes: {unmatched} method(s)",
                "",
                "Check aggregate report module dependencies and JaCoCo exclusions for absent classes.",
                "Check crap4java source-to-bytecode matching for methods in present classes.",
                "",
            ]
            for gap in sorted(coverage_gaps, key=lambda item: (item["reason"], item["class"], item["method"], item["file"], item["line"])):
                lines.append(f"{gap['reason']}: {gap['class']}#{gap['method']} at {gap['file']}:{gap['line']} [XML: {gap['jacoco_xml']}]")
            gap_report.write_text("\n".join(lines) + "\n")
            print(f"Coverage diagnosis: {absent} method(s) in classes absent from JaCoCo XML; {unmatched} method(s) not matched in present classes.", file=sys.stderr)
            print(f"Coverage gaps: {gap_report}", file=sys.stderr)
        return 2
    entries.sort(key=lambda entry: (-(entry["crap"] if entry["crap"] is not None else -1), entry["file"], entry["line"], entry["symbol"]))
    warnings = [entry for entry in entries if entry["crap"] is not None and entry["crap"] > args.threshold]
    gate = {"mode": "report-only", "warnings": len(warnings), "status": "reported"}
    if args.max_warnings is not None:
        gate = {"mode": "ratchet", "max_warnings": args.max_warnings, "warnings": len(warnings), "status": "passed" if len(warnings) <= args.max_warnings else "failed"}
    report = {
        "schema": "https://github.com/antonillos/makevn/crap-report-v1.json",
        "formula": "CC^2 * (1 - coverage)^3 + CC",
        "threshold": args.threshold,
        "entries": entries,
        "diagnostics": {"java_methods": len(entries), "missing_coverage": missing_coverage},
        "gate": gate,
    }
    if changes:
        report["scope"] = "changes"
        report["base"] = changes["base"]
        report["merge_base"] = changes["merge_base"]
    out = Path(args.output_dir)
    out.mkdir(parents=True, exist_ok=True)
    (out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    lines = ["# CRAP Changes Report" if changes else "# CRAP Report", "", f"**Status:** {gate['status'].upper()}", f"**Threshold:** CRAP > {args.threshold:g}", "", "| Location | Symbol | CRAP | CC | Coverage |", "|---|---|---:|---:|---:|"]
    for entry in warnings[:25]:
        coverage = "N/A" if entry["coverage_percent"] is None else f"{entry['coverage_percent']:.2f}%"
        lines.append(f"| `{entry['file']}:{entry['line']}` | {entry['symbol'].replace('|', chr(92) + '|')} | {score(entry['crap'])} | {score(entry['complexity'])} | {coverage} |")
    if not warnings:
        lines.append("| — | No findings exceed the threshold | — | — | — |")
    (out / "report.md").write_text("\n".join(lines) + "\n")
    sarif_results = [{"ruleId": "CRAP", "level": "warning", "message": {"text": f"{entry['symbol']} CRAP={score(entry['crap'])}, CC={score(entry['complexity'])}."}, "locations": [{"physicalLocation": {"artifactLocation": {"uri": entry["file"]}, "region": {"startLine": entry["line"]}}}]} for entry in warnings]
    sarif = {"version": "2.1.0", "$schema": "https://json.schemastore.org/sarif-2.1.0.json", "runs": [{"tool": {"driver": {"name": "makevn-crap", "informationUri": "https://github.com/antonillos/crap4java"}}, "results": sarif_results}]}
    (out / "report.sarif").write_text(json.dumps(sarif, indent=2) + "\n")
    summary = ["CRAP changes report completed" if changes else "CRAP report completed", f"Gate: {gate['status'].upper()}" + (f" ({len(warnings)}/{args.max_warnings} warnings)" if args.max_warnings is not None else " (no warning-count limit configured)"), f"Methods: {len(entries)}", f"Warnings: {len(warnings)}", f"Missing coverage: {report['diagnostics']['missing_coverage']}"]
    if changes:
        summary.insert(1, f"Base: {changes['base']}")
    (out / "summary.txt").write_text("\n".join(summary) + "\n")
    return 1 if gate["status"] == "failed" else 0


if __name__ == "__main__":
    raise SystemExit(main())
