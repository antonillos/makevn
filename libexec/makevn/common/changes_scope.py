"""Conservative, static reactor selection; never execute repository code."""
import pathlib
import subprocess
import sys
import xml.etree.ElementTree as ET


def parse(text):
    root = ET.fromstring(text)
    for node in root.iter():
        node.tag = node.tag.rsplit("}", 1)[-1]
    return root


def property_bumps(old, new):
    """Only root property-text changes are eligible for narrow selection."""
    before, after = old.find("properties"), new.find("properties")
    if before is None or after is None:
        return None
    changed = set()
    if [n.tag for n in before] != [n.tag for n in after]:
        return None
    for left, right in zip(before, after):
        if left.text != right.text:
            changed.add(left.tag)
            left.text = right.text
    # Ignore formatting, not XML structure, attributes or any other values.
    for root in (old, new):
        for node in root.iter():
            if node.text is not None:
                node.text = node.text.strip()
            node.tail = None
    return changed if ET.tostring(old) == ET.tostring(new) else None


def bump_consumers(base, previous, current):
    changed = property_bumps(previous, current)
    if not changed or any(not key.endswith("version") for key in changed):
        return None
    managed = {}
    for dependency in current.findall("./dependencyManagement/dependencies/dependency"):
        version = dependency.findtext("version", "")
        if version in {"${" + key + "}" for key in changed}:
            if version[2:-1] in managed:
                return None
            managed[version[2:-1]] = (dependency.findtext("groupId"), dependency.findtext("artifactId"))
    # Plugins, profile properties, indirection and unclassified bumps fall back.
    references = [node.text for node in current.iter() if node.text and "${" in node.text]
    if any(references.count("${" + key + "}") != 1 for key in changed):
        return None
    if set(managed) != changed:
        return None
    consumers = set()
    for pom in base.rglob("pom.xml"):
        if "target" in pom.relative_to(base).parts or pom == base / "pom.xml":
            continue
        root = parse(pom.read_text())
        if any(root.find("./properties/" + key) is not None for key in changed):
            return None
        # Narrowing assumes an immediate local parent; deeper inheritance is unknown.
        dependencies = root.findall("./dependencies/dependency")
        for dependency in root.findall(".//dependency"):
            coordinate = (dependency.findtext("groupId"), dependency.findtext("artifactId"))
            if coordinate in managed.values() and dependency not in dependencies:
                return None
        for dependency in dependencies:
            coordinate = (dependency.findtext("groupId"), dependency.findtext("artifactId"))
            if coordinate in managed.values():
                if root.findtext("./parent/artifactId") != current.findtext("artifactId"):
                    return None
                consumers.add(pom.parent.relative_to(base).as_posix())
    return consumers or None


def documentation_path(path):
    if '/src/' in path or path.startswith(('src/', '.mvn/')):
        return False
    return pathlib.Path(path).suffix.lower() in {'.md', '.rst'} or path.startswith('docs/') or pathlib.Path(path).name in {'LICENSE', 'NOTICE', 'README.txt'}


def selection(repo, base, reference, paths):
    modules = set()
    for path in paths:
        absolute = repo / path
        if documentation_path(path):
            continue
        if not absolute.is_relative_to(base):
            return "."
        relative = absolute.relative_to(base).as_posix()
        if "/src/" in relative:
            modules.add(relative.split("/src/", 1)[0])
        elif relative.startswith("src/"):
            return "."
        elif relative.endswith("pom.xml"):
            if absolute != base / "pom.xml":
                return "."
            old = subprocess.run(["git", "-C", str(repo), "show", reference + ":" + path],
                                 capture_output=True, text=True, check=True).stdout
            consumers = bump_consumers(base, parse(old), parse(absolute.read_text()))
            if consumers is None:
                return "."
            modules.update(consumers)
        else:
            return "."  # Unclassified files may alter the whole build.
    return ",".join(sorted(modules))


def focused_plan(repo, base, reference, paths):
    """Full suites for production/POM owners, changed tests in other owners."""
    production = [path for path in paths if "/src/test/java/" not in path]
    full = selection(repo, base, reference, production)
    if full == ".":
        raise ValueError("Unknown or root-level impact; use --exhaustive")
    suites = set(filter(None, full.split(",")))
    tests = {}
    for path in paths:
        if "/src/test/java/" not in path:
            continue
        absolute = repo / path
        if not absolute.is_relative_to(base):
            continue
        owner, name = absolute.relative_to(base).as_posix().split("/src/test/java/", 1)
        if not absolute.is_file() or not name.endswith(("Test.java", "IT.java", "Tests.java", "TestCase.java")):
            suites.add(owner)  # Helpers/deletions require the owner's entire suite.
        else:
            tests.setdefault(owner, set()).add(name[:-5].replace("/", "."))
    records = []
    for owner in sorted(suites | tests.keys()):
        if not (base / owner / "pom.xml").is_file():
            raise ValueError("No owner POM for " + owner + "; use --exhaustive")
        records.append(owner + "\t" + ("*" if owner in suites else ",".join(sorted(tests[owner]))))
    return "\n".join(records)


if __name__ == "__main__":
    focused = "--focused-plan" in sys.argv
    try:
        planner = focused_plan if focused else selection
        print(planner(pathlib.Path(sys.argv[1]).resolve(), pathlib.Path(sys.argv[2]).resolve(),
                      sys.argv[3], sys.stdin.read().splitlines()))
    except (OSError, ValueError, ET.ParseError, subprocess.CalledProcessError) as error:
        if focused:
            print("Cannot safely focus verification: " + str(error), file=sys.stderr)
            sys.exit(2)
        # Unknown model/deletion must not silently omit verification.
        print(".")
