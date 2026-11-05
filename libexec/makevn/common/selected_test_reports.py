"""Require fresh evidence for each explicitly selected focused test class."""
import pathlib
import sys
import xml.etree.ElementTree as ET


def is_integration(module, name):
    # Plugin naming conventions, not Spring annotations, determine ownership.
    simple_name = name.rsplit(".", 1)[-1]
    return simple_name.startswith("IT") or simple_name.endswith(("IT", "ITCase"))


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


def fresh_reports(module, directory, started):
    for report in (module / "target" / directory).rglob("TEST-*.xml"):
        if report.stat().st_mtime_ns >= started:
            yield report


def missing_tests(module, names, stamp, optional=()):
    started = stamp.stat().st_mtime_ns
    executed = {"surefire-reports": set(), "failsafe-reports": set()}
    for directory in ("surefire-reports", "failsafe-reports"):
        for report in fresh_reports(module, directory, started):
            root = ET.parse(report).getroot()
            for test in root.iter("testcase"):
                name = test.get("classname", "").split("$")[0]
                if test.find("failure") is not None or test.find("error") is not None:
                    raise ValueError("Selected test failed: " + name)
                if test.find("skipped") is None or name in optional:
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
        optional = set()
        if len(sys.argv) > 4:
            from test_impact import sealed_load, state, digest
            repo = pathlib.Path(sys.argv[4])
            path = state(repo) / 'map.json'
            if path.is_file():
                try:
                    value = sealed_load(path)
                    if value['status'] == 'success' and pathlib.Path(value['base']).resolve() == pathlib.Path(sys.argv[1]).resolve():
                        optional = set(value.get('skipped', {}))
                except (OSError, ValueError, KeyError, TypeError):
                    pass
            from progressive_impact import load, CONDITIONAL
            from reactor_test_impact import is_source
            try:
                value = load(repo)
                module = pathlib.Path(sys.argv[1]).resolve()
                if module.is_relative_to(pathlib.Path(value['base']).resolve()):
                    unchanged = {item['class'] for source, item in value['facts'].items()
                                 if is_source(source, 'test') and
                                 (pathlib.Path(value['base']) / item.get('owner', '.')).resolve() == module and
                                 (pathlib.Path(value['base']) / source).is_file() and
                                 value['inputs'].get((pathlib.Path(value['base']) / source).relative_to(repo).as_posix()) ==
                                 digest(pathlib.Path(value['base']) / source)}
                    eligible = (set(value.get('skipped', {})) & unchanged) | {
                        item['class'] for item in value['facts'].values()
                        if item['class'] in unchanged and CONDITIONAL.intersection(item['names'])}
                    optional.update(name.split('::', 1)[-1] for name in eligible)
            except (OSError, ValueError, KeyError, TypeError):
                pass
        missing = missing_tests(pathlib.Path(sys.argv[1]), sys.argv[2].split(","), pathlib.Path(sys.argv[3]), optional)
        if missing:
            print("No fresh executed-test evidence for: " + ",".join(missing), file=sys.stderr)
            sys.exit(1)
    except (OSError, ValueError, ET.ParseError) as error:
        print("Cannot verify selected test reports: " + str(error), file=sys.stderr)
        sys.exit(1)
