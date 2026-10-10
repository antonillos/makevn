"""Require fresh evidence for each explicitly selected focused test class."""
import pathlib
import sys
import xml.etree.ElementTree as ET


def is_integration(module, name):
    annotations = ("@SpringBootTest", "@DataMongoTest", "@WebMvcTest", "@Testcontainers")
    source = module / "src/test/java" / (name.replace(".", "/") + ".java")
    content = source.read_text() if source.is_file() else ""
    return name.endswith("IT") or any(marker in content for marker in annotations)


def selection_flags(module, names):
    unit, integration = [], []
    for name in names:
        destination = integration if is_integration(module, name) else unit
        destination.append(name)
    # Never send the same IT to Surefire AND Failsafe; an exclusion-only regex
    # selects no classes in the other plugin without disabling test compilation.
    return ["-Dtest=" + (",".join(unit) or "!%regex[.*]"),
            "-Dit.test=" + (",".join(integration) or "!%regex[.*]"),
            "-Dsurefire.failIfNoSpecifiedTests=false", "-Dfailsafe.failIfNoSpecifiedTests=false"]


def missing_tests(module, names, stamp):
    started = stamp.stat().st_mtime_ns
    executed = {"surefire-reports": set(), "failsafe-reports": set()}
    for directory in ("surefire-reports", "failsafe-reports"):
        for report in (module / "target" / directory).glob("TEST-*.xml"):
            if report.stat().st_mtime_ns < started:
                continue
            root = ET.parse(report).getroot()
            for test in root.iter("testcase"):
                if test.find("skipped") is None:
                    executed[directory].add(test.get("classname", ""))
    missing = []
    for name in names:
        directory = "failsafe-reports" if is_integration(module, name) else "surefire-reports"
        if not any(actual == name or actual.startswith(name + "$") for actual in executed[directory]):
            missing.append(name)
    return missing


if __name__ == "__main__":
    try:
        if sys.argv[1] == "--flags":
            print("\n".join(selection_flags(pathlib.Path(sys.argv[2]), sys.argv[3].split(","))))
            sys.exit(0)
        missing = missing_tests(pathlib.Path(sys.argv[1]), sys.argv[2].split(","), pathlib.Path(sys.argv[3]))
        if missing:
            print("No fresh executed-test evidence for: " + ",".join(missing), file=sys.stderr)
            sys.exit(1)
    except (OSError, ET.ParseError) as error:
        print("Cannot verify selected test reports: " + str(error), file=sys.stderr)
        sys.exit(1)
