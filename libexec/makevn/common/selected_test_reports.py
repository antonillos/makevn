"""Require fresh evidence for each explicitly selected focused test class."""
import pathlib
import sys
import xml.etree.ElementTree as ET


def missing_tests(module, names, stamp):
    started = stamp.stat().st_mtime_ns
    executed = set()
    for directory in ("surefire-reports", "failsafe-reports"):
        for report in (module / "target" / directory).glob("TEST-*.xml"):
            if report.stat().st_mtime_ns < started:
                continue
            root = ET.parse(report).getroot()
            for test in root.iter("testcase"):
                if test.find("skipped") is None:
                    executed.add(test.get("classname", ""))
    return [name for name in names if not any(actual == name or actual.startswith(name + "$") for actual in executed)]


if __name__ == "__main__":
    try:
        missing = missing_tests(pathlib.Path(sys.argv[1]), sys.argv[2].split(","), pathlib.Path(sys.argv[3]))
        if missing:
            print("No fresh executed-test evidence for: " + ",".join(missing), file=sys.stderr)
            sys.exit(1)
    except (OSError, ET.ParseError) as error:
        print("Cannot verify selected test reports: " + str(error), file=sys.stderr)
        sys.exit(1)
