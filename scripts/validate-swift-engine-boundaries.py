"""Validate the Swift engine's module boundary without building the package."""

import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "scripts/fixtures/swift-engine-boundaries"
ENGINE = "RunPlayEngine"
SUPPORT = "RunPlayEngineTestSupport"
ALLOWED_ENGINE_IMPORTS = {"Swift", "Darwin", "Glibc", "Musl", "Android"}
SWIFT_IMPORT = re.compile(
    r"(?<![.\w])(?P<attributes>(?:@\w+\s+)*)"
    r"(?:(?P<access>public|package|internal|fileprivate|private)\s+)?"
    r"import\s+"
    r"(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?"
    r"`?(?P<module>[A-Za-z_][A-Za-z_0-9]*)`?"
)
COMMENT_DELIMITER = re.compile(r"/\*|\*/")
# An extended regex literal (`#/.../#`, with any number of `#`) is skipped like
# a string, so words inside it are not read as an import. A bare `/.../` regex
# literal is not recognized: it cannot be told from division without parsing,
# and leaving it in can only report a violation that is not there, never hide
# an import.
TOKENS = re.compile(r'//[^\n]*|/\*|\*/|(?P<regex>\#+)/|(?P<hashes>\#*)(?P<quote>"""|")')


def source_without_comments_or_strings(source):
    """Keep token separators, including line numbers, outside nested comments/literals."""
    output = []
    start = 0
    end = 0
    while match := TOKENS.search(source, end):
        end = match.end()
        token = match.group()
        if token == "*/":
            continue
        output.append(source[start:match.start()])
        if token == "/*":
            depth = 1
            while depth:
                delimiter = COMMENT_DELIMITER.search(source, end)
                if delimiter is None:
                    end = len(source)
                    break
                end = delimiter.end()
                depth += 1 if delimiter.group() == "/*" else -1
        elif match["regex"]:
            close = re.compile(r"\\[\s\S]|/" + re.escape(match["regex"]))
            for candidate in close.finditer(source, end):
                if not candidate.group().startswith("\\"):
                    end = candidate.end()
                    break
            else:
                end = len(source)
        elif not token.startswith("//"):
            quote = match["quote"]
            hashes = match["hashes"]
            escaped_character = r"\\" + re.escape(hashes) + r"[\s\S]"
            close = re.compile(escaped_character + "|" + re.escape(quote + hashes))
            for candidate in close.finditer(source, end):
                if candidate.group() == quote + hashes:
                    end = candidate.end()
                    break
            else:
                end = len(source)
        output.append(" " + "\n" * source[match.start():end].count("\n"))
        start = end
    output.append(source[start:])
    return "".join(output)


def import_violations(relative, source):
    is_engine_source = relative.parts[:2] == ("RunPlayEngine", "Sources")
    is_engine_test = relative.parts[:2] == ("RunPlayEngine", "Tests")
    is_core_source = relative.parts[:2] == ("RunPlayCore", "Sources")
    code = source_without_comments_or_strings(source)
    for match in SWIFT_IMPORT.finditer(code):
        exported = "@_exported" in match["attributes"].split()
        access, module = match["access"], match["module"]
        line = code.count("\n", 0, match.start()) + 1
        if is_engine_source and module not in ALLOWED_ENGINE_IMPORTS:
            yield f"{relative}:{line}: engine cannot import {module}"
        if module == ENGINE and (
            exported or not (is_engine_test or (is_core_source and access == "internal"))
        ):
            yield f"{relative}:{line}: unauthorized {ENGINE} import"


def graph_violations(manifest):
    targets = {
        target["name"]: (target["type"], {next(iter(dep.values()))[0] for dep in target["dependencies"]})
        for target in manifest["targets"]
    }
    if targets.get(ENGINE) != ("regular", set()):
        yield f"{ENGINE} must be a regular target with no dependencies"
    if targets.get(SUPPORT) != ("regular", set()):
        yield f"{SUPPORT} must be a regular target with no dependencies"

    expected = {"RunPlayCore": "regular", "RunPlayEngineTests": "test"}
    consumers = {name: kind for name, (kind, dependencies) in targets.items() if ENGINE in dependencies}
    if consumers != expected:
        yield f"{ENGINE} consumers must be Core and the engine's own unit tests"
    consumers = {name: kind for name, (kind, dependencies) in targets.items() if SUPPORT in dependencies}
    if consumers != {"RunPlayCoreTests": "test", "RunPlayEngineTests": "test"}:
        yield f"{SUPPORT} must only be consumed by the Core and engine tests"
    for product in manifest["products"]:
        if {ENGINE, SUPPORT}.intersection(product["targets"]):
            yield f"product {product['name']} must not expose either engine or test support as a root"


def self_test():
    cases = (
        ("engine-foundation.swift", "RunPlayEngine/Sources/Kernel.swift", "engine cannot import Foundation"),
        ("platform-engine.swift", "RunPlayPlatform/Sources/Adapter.swift", "unauthorized RunPlayEngine import"),
        ("core-unqualified.swift", "RunPlayCore/Sources/Adapter.swift", "unauthorized RunPlayEngine import"),
        ("core-exported.swift", "RunPlayCore/Sources/Adapter.swift", "unauthorized RunPlayEngine import"),
        ("core-exported-modifiers.swift", "RunPlayCore/Sources/Adapter.swift", "unauthorized RunPlayEngine import"),
        ("core-commented-and-raw.swift", "RunPlayCore/Sources/Adapter.swift", None),
        ("platform-ignored.swift", "RunPlayPlatform/Sources/Adapter.swift", None),
        ("platform-regex-literals.swift", "RunPlayPlatform/Sources/Adapter.swift", None),
        ("platform-regex-then-import.swift", "RunPlayPlatform/Sources/Adapter.swift",
         "unauthorized RunPlayEngine import"),
        ("platform-engine.swift", "Tests/PackageConsumerSmoke/Sources/Smoke/main.swift",
         "unauthorized RunPlayEngine import"),
    )
    for filename, relative, expected in cases:
        source = (FIXTURES / filename).read_text(encoding="utf-8")
        errors = list(import_violations(Path(relative), source))
        actual = [error.split(": ", 1)[1] for error in errors]
        if actual != ([expected] if expected else []):
            raise ValueError(f"{filename} as {relative}: expected {expected!r}; got {errors}")


def main():
    self_test()
    errors = []
    owners = (
        "RunPlayEngine", "RunPlayEngineCpp", "RunPlayCore", "RunPlayPlatform",
        "RunPlayStudio", "Tests/PackageConsumerSmoke",
    )
    for target in owners:
        for directory, folders, filenames in os.walk(ROOT / target):
            folders[:] = sorted(folder for folder in folders if not folder.startswith("."))
            for filename in sorted(name for name in filenames if name.endswith(".swift")):
                path = Path(directory) / filename
                errors.extend(import_violations(path.relative_to(ROOT), path.read_text(encoding="utf-8")))

    # Ask SwiftPM which targets are actually declared, including host conditionals.
    manifest = subprocess.check_output(["swift", "package", "dump-package"], cwd=ROOT, text=True)
    errors.extend(graph_violations(json.loads(manifest)))
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("Swift engine import boundaries and target graph verified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
