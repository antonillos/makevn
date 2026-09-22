#!/usr/bin/env python3
import argparse
import csv
import json
import sys
from pathlib import Path


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--complexity", required=True)
    parser.add_argument("--coverage", required=True)
    parser.add_argument("--output", required=True)
    return parser.parse_args()


def coverage_files(payload):
    merged = {}
    for result in payload.values():
        coverage = result.get("coverage", {}) if isinstance(result, dict) else {}
        for path, value in coverage.items():
            lines = value.get("lines", value) if isinstance(value, dict) else value
            if not isinstance(lines, list):
                continue
            current = merged.setdefault(str(Path(path).resolve()), [None] * len(lines))
            if len(current) < len(lines):
                current.extend([None] * (len(lines) - len(current)))
            for index, hits in enumerate(lines):
                if hits is not None:
                    current[index] = (current[index] or 0) + hits
    return merged


def main():
    args = parse_args()
    root = Path(args.root).resolve()
    try:
        coverage = coverage_files(json.loads(Path(args.coverage).read_text()))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"Error: invalid Bashcov result set: {exc}", file=sys.stderr)
        return 2
    metrics = []
    try:
        with Path(args.complexity).open(newline="") as handle:
            for row in csv.DictReader(handle):
                if row["func"] in ("<begin>", "<end>"):
                    continue
                source = (root / row["file"]).resolve() if not Path(row["file"]).is_absolute() else Path(row["file"]).resolve()
                if root not in source.parents and source != root:
                    raise ValueError(f"source escapes repository: {source}")
                metrics.append({"source": source, "file": str(source.relative_to(root)), "function": row["func"], "line": max(1, int(row["lineno"] or 0)), "cyclomatic": int(row["ccn"])})
    except (OSError, KeyError, ValueError) as exc:
        print(f"Error: invalid ShellMetrics CSV: {exc}", file=sys.stderr)
        return 2
    if not metrics:
        print("Error: ShellMetrics produced no functions.", file=sys.stderr)
        return 2

    by_file = {}
    for metric in metrics:
        by_file.setdefault(metric["source"], []).append(metric)
    entries = []
    missing = []
    for source, functions in by_file.items():
        lines = coverage.get(str(source))
        if lines is None:
            missing.append(str(source.relative_to(root)))
        functions.sort(key=lambda item: (item["line"], item["function"] == "<main>"))
        file_lines = len(source.read_text().splitlines())
        starts = sorted({item["line"] for item in functions if item["function"] != "<main>"})
        for item in functions:
            start = item["line"]
            if item["function"] == "<main>":
                start, end = 1, file_lines
            else:
                later = [line for line in starts if line > start]
                end = (later[0] - 1) if later else file_lines
            executable = [] if lines is None else [hit for hit in lines[start - 1:end] if hit is not None]
            covered = sum(hit > 0 for hit in executable)
            percent = None if not executable else covered * 100.0 / len(executable)
            complexity = item["cyclomatic"]
            crap = None if percent is None else complexity ** 2 * (1 - percent / 100.0) ** 3 + complexity
            entries.append({"file": item["file"], "line": start, "end_line": end, "function": item["function"], "cyclomatic": complexity, "coverage": percent, "crap": crap, "status": "measured" if crap is not None else "missing-coverage"})
    if missing:
        print("Error: Bash coverage is missing production files: " + ", ".join(sorted(missing)[:10]), file=sys.stderr)
        return 2
    if not any(entry["crap"] is not None for entry in entries):
        print("Error: shell CRAP report contains no measured functions.", file=sys.stderr)
        return 2
    Path(args.output).write_text(json.dumps({"entries": entries, "diagnostics": {"functions": len(entries), "missing_coverage": 0}}, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
