#!/usr/bin/env python3
import argparse
import json
import sys
from pathlib import Path


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--rust", required=True)
    parser.add_argument("--shell", required=True)
    parser.add_argument("--baseline", required=True)
    parser.add_argument("--base-baseline")
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--threshold", type=float, default=8.0)
    return parser.parse_args()


def normalized(language, entry, root, threshold):
    file_name = entry.get("file", "")
    try:
        file_name = str(Path(file_name).resolve().relative_to(root)) if Path(file_name).is_absolute() else file_name
    except ValueError:
        pass
    crap = entry.get("crap")
    line = entry.get("line", 1)
    end_line = entry.get("end_line") or line
    return {
        "language": language,
        "file": file_name,
        "line": line,
        "end_line": end_line,
        "range": {"start_line": line, "end_line": end_line},
        "symbol": entry.get("function", "<unknown>"),
        "complexity": entry.get("cyclomatic"),
        "coverage_percent": entry.get("coverage"),
        "crap": crap,
        "status": entry.get("status", "measured" if crap is not None else "missing-coverage"),
        "recommendation": "reduce complexity or add focused tests" if crap is not None and crap > threshold else "none",
    }


def load_json(path, description):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"invalid {description}: {exc}") from exc


def main():
    args = parse_args()
    try:
        rust = load_json(args.rust, "Rust report")
        shell = load_json(args.shell, "shell report")
        baseline = load_json(args.baseline, "baseline")
        base_baseline = load_json(args.base_baseline, "base-branch baseline") if args.base_baseline else baseline
        for payload, name in ((rust, "Rust"), (shell, "shell")):
            if not isinstance(payload.get("entries"), list) or not payload["entries"]:
                raise ValueError(f"{name} report contains no entries")
        limits = baseline["max_warnings"]
        old_limits = base_baseline["max_warnings"]
        for language in ("rust", "shell"):
            if not isinstance(limits[language], int) or limits[language] < 0:
                raise ValueError(f"invalid {language} baseline")
            if limits[language] > old_limits[language]:
                raise ValueError(f"{language} baseline cannot increase ({old_limits[language]} -> {limits[language]})")
        if limits.get("total") != limits["rust"] + limits["shell"]:
            raise ValueError("baseline total must equal the Rust and shell limits")
    except (KeyError, TypeError, ValueError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 2

    root = Path.cwd().resolve()
    entries = [normalized("rust", entry, root, args.threshold) for entry in rust["entries"]] + [normalized("shell", entry, root, args.threshold) for entry in shell["entries"]]
    if any(entry["crap"] is None for entry in entries):
        print("Error: CRAP evidence has functions without coverage.", file=sys.stderr)
        return 2
    entries.sort(key=lambda entry: (-entry["crap"], entry["language"], entry["file"], entry["line"]))
    warnings = {language: sum(entry["language"] == language and entry["crap"] > args.threshold for entry in entries) for language in ("rust", "shell")}
    failures = [language for language in ("rust", "shell") if warnings[language] > limits[language]]
    status = "failed" if failures else "passed"
    report = {"schema": "https://github.com/antonillos/makevn/crap-report-v1.json", "formula": "CC^2 * (1 - coverage)^3 + CC", "threshold": args.threshold, "entries": entries, "diagnostics": {"rust_functions": len(rust["entries"]), "shell_functions": len(shell["entries"]), "missing_coverage": 0}, "gate": {"mode": "baseline-ratchet", "status": status, "warnings": {**warnings, "total": warnings["rust"] + warnings["shell"]}, "max_warnings": {**limits, "total": limits["rust"] + limits["shell"]}}}
    out = Path(args.output_dir)
    out.mkdir(parents=True, exist_ok=True)
    (out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    findings = [entry for entry in entries if entry["crap"] > args.threshold]
    lines = ["# CRAP Report", "", f"**Status:** {status.upper()}", f"**Threshold:** CRAP > {args.threshold:g}", "", "| Language | Functions | Warnings | Baseline |", "|---|---:|---:|---:|", f"| Rust | {len(rust['entries'])} | {warnings['rust']} | {limits['rust']} |", f"| Shell | {len(shell['entries'])} | {warnings['shell']} | {limits['shell']} |", f"| **Total** | **{len(entries)}** | **{len(findings)}** | **{limits['rust'] + limits['shell']}** |", "", "| Location | Symbol | CRAP | CC | Coverage |", "|---|---|---:|---:|---:|"]
    for entry in findings[:25]:
        lines.append(f"| `{entry['file']}:{entry['line']}` | {entry['symbol']} | {entry['crap']:.2f} | {entry['complexity']:.2f} | {entry['coverage_percent']:.2f}% |")
    (out / "report.md").write_text("\n".join(lines) + "\n")
    sarif_results = [{"ruleId": "CRAP", "level": "warning", "message": {"text": f"{entry['symbol']} CRAP={entry['crap']:.2f}, CC={entry['complexity']:.2f}, coverage={entry['coverage_percent']:.2f}%."}, "locations": [{"physicalLocation": {"artifactLocation": {"uri": entry["file"]}, "region": {"startLine": entry["line"]}}}]} for entry in findings]
    (out / "report.sarif").write_text(json.dumps({"version": "2.1.0", "$schema": "https://json.schemastore.org/sarif-2.1.0.json", "runs": [{"tool": {"driver": {"name": "makevn-crap"}}, "results": sarif_results}]}, indent=2) + "\n")
    total = warnings["rust"] + warnings["shell"]
    color = "brightgreen" if total == 0 else "yellow" if total <= 50 else "orange" if total <= 100 else "red"
    (out / "badge.json").write_text(json.dumps({"schemaVersion": 1, "label": "CRAP", "message": f"{total} warnings", "color": color, "cacheSeconds": 300}, indent=2) + "\n")
    summary = f"CRAP report completed\nGate: {status.upper()}\nRust: {warnings['rust']}/{limits['rust']} warnings\nShell: {warnings['shell']}/{limits['shell']} warnings\nTotal: {total} warnings\n"
    (out / "summary.txt").write_text(summary)
    print(summary, end="")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
