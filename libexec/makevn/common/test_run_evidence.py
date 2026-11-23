"""Summarize conventional Maven test reports written during a test invocation."""

import os
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET

from selected_test_reports import fresh_reports


DIRECTORIES = ("surefire-reports", "failsafe-reports")
CACHE_WARNING = "Cached build doesn't contain all requested plugin executions"


def report_groups(root, directory):
    if directory:
        yield root, directory
        return
    for path, children, files in os.walk(root):
        children[:] = [name for name in children if name not in {"target", ".git", ".makevn"}]
        if "pom.xml" in files:
            yield from ((Path(path), name) for name in DIRECTORIES)


def summarize(root, directory, started, selector):
    test_class, _, method = selector.partition("#")
    reports = executed = failed = skipped = 0
    complete = True
    for module, plugin_directory in report_groups(root, directory):
        try:
            for report in fresh_reports(module, plugin_directory, started):
                suite = ET.parse(report).getroot()
                if suite.tag != "testsuite":
                    complete = False
                    continue
                reports += 1
                for case in suite.iter("testcase"):
                    if test_class and case.get("classname", "").split("$")[0] != test_class:
                        continue
                    if method and re.split(r"[\[(]", case.get("name", ""), maxsplit=1)[0] != method:
                        continue
                    if case.find("skipped") is not None:
                        skipped += 1
                    else:
                        executed += 1
                        failed += case.find("failure") is not None or case.find("error") is not None
        except (OSError, ET.ParseError):
            complete = False
    if reports and complete:
        print(f"Test evidence: {executed} executed, {failed} failed, {skipped} skipped (fresh Maven XML)")
    else:
        print("Test evidence: unavailable (no complete set of fresh conventional Maven XML reports)")
    return not method or (complete and executed > 0)


def warn_about_cache(log, started):
    try:
        if log.stat().st_mtime_ns < started:
            return
        with log.open(errors="replace") as lines:
            if any(CACHE_WARNING in line for line in lines):
                print("Maven build cache warning: cached build lacks requested plugin executions; check fresh test evidence.")
    except OSError:
        pass


if __name__ == "__main__":
    root, directory, start, selector, log = sys.argv[1:]
    started = int(start)
    verified = summarize(Path(root), directory, started, selector)
    warn_about_cache(Path(log), started)
    if not verified:
        print(f"No fresh executed-test evidence for {selector}", file=sys.stderr)
        sys.exit(1)
