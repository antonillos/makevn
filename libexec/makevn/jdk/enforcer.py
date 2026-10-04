#!/usr/bin/env python3
"""Read unconditional local Enforcer Java rules without invoking Maven.

This is not an effective-POM evaluator: remote parents and profile activation
remain Maven's responsibility. Unresolvable local rules fail closed.
"""
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def models(pom, seen=None):
    seen = set() if seen is None else seen
    pom = pom.resolve()
    if pom in seen:
        raise ValueError("cyclic local parent POM")
    seen.add(pom)
    root = ET.parse(pom).getroot()
    for node in root.iter():
        node.tag = node.tag.rsplit("}", 1)[-1]
    parent = root.find("parent")
    result = []
    if parent is not None:
        relative = parent.find("relativePath")
        name = "../pom.xml" if relative is None else (relative.text or "").strip()
        candidate = pom.parent / name
        if name and candidate.is_file():
            result = models(candidate, seen)
    return result + [root]


def expand(value, properties):
    for _ in range(20):
        updated = re.sub(r"\$\{([^}]+)\}", lambda m: properties.get(m[1], m[0]), value)
        if updated == value:
            break
        value = updated
    if "${" in value:
        raise ValueError("unresolved Enforcer property: " + value)
    return value.strip()


def number(value):
    if not re.fullmatch(r"\d+(?:[._]\d+)*(?:-\d+)?", value):
        raise ValueError("unsupported Enforcer version: " + value)
    parts = tuple(map(int, re.split(r"[._-]", value)))
    # Enforcer's special handling of the Java 8 shorthand.
    return (1, 8) + parts[1:] if parts[0] == 8 else parts


def compare(left, right):
    size = max(len(left), len(right))
    left += (0,) * (size - len(left))
    right += (0,) * (size - len(right))
    return (left > right) - (left < right)


def intervals(value):
    if not value.startswith(("[", "(")):
        return [(number(value), True, None, False)]
    result = []
    remaining = value
    while remaining:
        match = re.match(r"(\[|\()([^\[\]()]*)(\]|\))", remaining)
        if not match:
            raise ValueError("unsupported Enforcer range: " + value)
        start, body, end = match.groups()
        if "," not in body:
            if start != "[" or end != "]":
                raise ValueError("invalid exact Enforcer range: " + value)
            bound = number(body.strip())
            result.append((bound, True, bound, True))
        else:
            low, high = body.split(",", 1)
            result.append((number(low.strip()) if low.strip() else None, start == "[",
                           number(high.strip()) if high.strip() else None, end == "]"))
        remaining = remaining[match.end():].strip()
        if remaining:
            if not remaining.startswith(","):
                raise ValueError("invalid Enforcer range union: " + value)
            remaining = remaining[1:].strip()
            if not remaining:
                raise ValueError("incomplete Enforcer range union: " + value)
    return result


def accepts(value, version):
    base, separator, build = version.partition("+")
    actual = number(base)
    if separator:
        build = build.removesuffix("-LTS")
        if not build.isdigit():
            raise ValueError("unsupported JDK build: " + version)
        actual += (0,) * max(0, 3 - len(actual)) + (int(build),)
    for low, low_closed, high, high_closed in intervals(value):
        lower = 1 if low is None else compare(actual, low)
        upper = -1 if high is None else compare(actual, high)
        if (lower > 0 or lower == 0 and low_closed) and (upper < 0 or upper == 0 and high_closed):
            return True
    return False


def rules(pom):
    roots = models(pom)
    properties = {}
    for root in roots:
        for prop in root.findall("properties/*"):
            properties[prop.tag] = prop.text or ""
    result = []
    for root in roots:
        for plugin in root.findall("build/plugins/plugin"):
            if plugin.findtext("artifactId") != "maven-enforcer-plugin":
                continue
            if plugin.findtext("groupId", "org.apache.maven.plugins") != "org.apache.maven.plugins":
                continue
            if root is not roots[-1] and plugin.findtext("inherited") == "false":
                continue
            shared = plugin.find("configuration")
            for execution in plugin.findall("executions/execution"):
                if execution.findtext("phase") == "none":
                    continue
                if "enforce" not in [goal.text for goal in execution.findall("goals/goal")]:
                    continue
                if root is not roots[-1] and execution.findtext("inherited") == "false":
                    continue
                specific = execution.find("configuration")
                configurations = [config for config in (shared, specific) if config is not None]
                skip = next((config.findtext("skip") for config in reversed(configurations)
                             if config.find("skip") is not None), "false")
                if expand(skip, properties).lower() == "true":
                    continue
                for config in configurations:
                    for rule in config.findall("rules/requireJavaVersion"):
                        value = expand(rule.findtext("version", ""), properties)
                        intervals(value)  # Validate before candidate filtering.
                        result.append(value)
    return list(dict.fromkeys(result))


def main(args):
    try:
        if args[0] == "rules":
            pom = Path(args[1]) / "pom.xml"
            if pom.is_file():
                print("\n".join(rules(pom)), end="")
            return 0
        return 0 if all(accepts(value, args[1]) for value in args[2:]) else 1
    except (ValueError, OSError, ET.ParseError) as error:
        if args[0] == "rules":
            print("!" + str(error), end="")
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
