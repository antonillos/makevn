"""Conservative, static reactor selection; never execute repository code."""
import pathlib
import subprocess
import sys
import xml.etree.ElementTree as ET

from reactor_impact import leaf_bump_owners, resource_owners, resource_rules


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
    if not any("${" + key + "}" in (node.text or "") for key in changed for node in current.iter()):
        return inherited_version_consumers(base, current, changed)
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


def declared_modules(base, current):
    """Resolve only literal unconditional modules in the local reactor graph."""
    base = base.resolve()
    pending, seen = [(base, current)], {base.resolve()}
    modules = set()
    while pending:
        directory, root = pending.pop()
        if root.findall('./profiles/profile/modules/module'):
            return None
        for node in root.findall('./modules/module'):
            name = (node.text or '').strip()
            owner = (directory / name).resolve()
            if not name or '${' in name or not owner.is_relative_to(base) or owner in seen:
                return None
            seen.add(owner)
            pom = owner / 'pom.xml'
            if not pom.is_file():
                return None
            modules.add(owner.relative_to(base).as_posix())
            pending.append((owner, parse(pom.read_text())))
    return modules


def inherited_version_consumers(base, current, changed):
    """Accept parent properties used only as direct child dependency versions."""
    tokens = {"${" + key + "}" for key in changed}
    reactor = declared_modules(base, current)
    if reactor is None:
        return None
    if any(token in value for node in current.iter() for value in node.attrib.values() for token in tokens):
        return None
    consumers, used = set(), set()
    for pom in base.rglob("pom.xml"):
        if "target" in pom.relative_to(base).parts or pom == base / "pom.xml":
            continue
        root = parse(pom.read_text())
        if any(root.find("./properties/" + key) is not None for key in changed):
            return None
        versions = root.findall("./dependencies/dependency/version")
        references = [node for node in root.iter()
                      if any(token in (node.text or "") or
                             any(token in value for value in node.attrib.values())
                             for token in tokens)]
        if not references:
            continue
        if pom.parent.relative_to(base).as_posix() not in reactor:
            return None  # Matching examples/standalone POMs are not -pl projects.
        parent = root.find("parent")
        if (parent is None or parent.findtext("artifactId") != current.findtext("artifactId") or
                (pom.parent / parent.findtext("relativePath", "../pom.xml")).resolve() != (base / "pom.xml").resolve()):
            return None
        if any(node not in versions or node.text not in tokens or node.attrib for node in references):
            return None  # Profiles, plugins and interpolation are not understood.
        used.update(node.text for node in references)
        consumers.add(pom.parent.relative_to(base).as_posix())
    return consumers if used == tokens and consumers else None


def non_verification_path(path):
    """Documentation and Git ignore rules outside source/build inputs."""
    documentation_suffixes = {'.md', '.rst', '.adoc', '.asciidoc'}
    # Antora uses docs/src/modules/...; that src is not a Maven source tree.
    if path.startswith('docs/') and pathlib.Path(path).suffix.lower() in documentation_suffixes:
        return True
    if '/src/' in path or path.startswith(('src/', '.mvn/')):
        return False
    return pathlib.Path(path).suffix.lower() in documentation_suffixes or path.startswith('docs/') or pathlib.Path(path).name in {'LICENSE', 'NOTICE', 'README.txt', '.gitignore'}


def selection(repo, base, reference, paths):
    repo, base = repo.resolve(), base.resolve()
    modules = set()
    for path in paths:
        absolute = repo / path
        if not path or non_verification_path(path):
            continue
        if not absolute.is_relative_to(base):
            return "."
        relative = absolute.relative_to(base).as_posix()
        if relative.startswith("src/"):
            if not relative.startswith("src/test/resources/"):
                return "."
            reactor = declared_modules(base, parse((base / "pom.xml").read_text()))
            if reactor is None:
                return "."
            owners = resource_owners(absolute, resource_rules(repo, base, reactor, parse))
            if not owners:
                raise ValueError("No declared shared-resource scope for " + path + "; declare its Maven consumers and externalChecks in makevn-impact.json, or use --exhaustive")
            modules.update(owners)
        elif "/src/" in relative:
            modules.add(relative.split("/src/", 1)[0])
        elif pathlib.Path(relative).name == "pom.xml":
            old = subprocess.run(["git", "-C", str(repo), "show", reference + ":" + path],
                                 capture_output=True, text=True, check=True).stdout
            current = parse(absolute.read_text())
            if absolute == base / "pom.xml":
                consumers = bump_consumers(base, parse(old), current)
            else:
                reactor = declared_modules(base, parse((base / "pom.xml").read_text()))
                if reactor is None:
                    return "."
                changed = property_bumps(parse(old), parse(absolute.read_text()))
                consumers = leaf_bump_owners(repo, base, absolute.parent.relative_to(base).as_posix(),
                    current, changed, reactor, resource_rules(repo, base, reactor, parse), parse)
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
        blockers = [path for path in production if selection(repo, base, reference, [path]) == "."]
        raise ValueError("Unknown or root-level impact in " + ", ".join(blockers) + "; use --exhaustive")
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
