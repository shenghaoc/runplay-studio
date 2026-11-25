"""Validate the Swift engine's module boundary without building the package."""

import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "scripts/fixtures/swift-engine-boundaries"
ENGINE = "RunPlayEngine"
SUPPORT = "RunPlayEngineTestSupport"
ALLOWED_ENGINE_IMPORTS = {"Swift", "Darwin", "Glibc", "Musl", "Android"}
# The package contains no C or C++ target. SwiftPM builds a target that holds
# any of these files as a C-family target, and a stray header in a Swift target
# is the start of one, so none may appear in a target directory.
C_FAMILY_SUFFIXES = {".c", ".cc", ".cpp", ".cxx", ".m", ".mm", ".h", ".hpp", ".hh", ".s", ".S"}
# The consumer smoke package is not a target of this package, but it builds
# against it, so it is held to the same rule.
EXTRA_SOURCE_DIRECTORIES = ("Tests/PackageConsumerSmoke",)
# RunPlayStudio is the app target of this Xcode project, not a SwiftPM target,
# so the package graph cannot see its edges. The project may link only these
# package products, all from the local package at the repository root.
PROJECT = ROOT / "RunPlayStudio.xcodeproj/project.pbxproj"
PROJECT_TARGETS = {"RunPlayStudio", "RunPlayStudioTests"}
LINKABLE_PRODUCTS = {"RunPlayCore", "RunPlayPlatform"}
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
    # A golden digest test hashes engine output directly, so it is the one
    # kind of Core test file that may import the engine.
    is_core_golden = (
        relative.parts[:3] == ("RunPlayCore", "Tests", "RunPlayCoreTests")
        and relative.name.endswith("GoldenTests.swift")
    )
    code = source_without_comments_or_strings(source)
    for match in SWIFT_IMPORT.finditer(code):
        exported = "@_exported" in match["attributes"].split()
        access, module = match["access"], match["module"]
        line = code.count("\n", 0, match.start()) + 1
        if is_engine_source and module not in ALLOWED_ENGINE_IMPORTS:
            yield f"{relative}:{line}: engine cannot import {module}"
        if module == ENGINE and (
            exported or not (is_engine_test or is_core_golden or (is_core_source and access == "internal"))
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
    # The package is pure Swift. An interoperability setting or a language
    # standard for another language would let a C or C++ target back in.
    for target in manifest["targets"]:
        if "interoperabilityMode" in json.dumps(target.get("settings", [])):
            yield f"target {target['name']} must not enable C++ interoperability"
    for key in ("cLanguageStandard", "cxxLanguageStandard"):
        if manifest.get(key) is not None:
            yield f"the package must not set {key}"


def project_violations(pbxproj):
    """Check the Xcode project's targets and package links from its text."""
    objects = re.findall(r"\n\t\t(\w{24}) (?:/\*.*?\*/ )?= \{(.*?)\};(?=\n)", pbxproj, re.S)
    isa = {key: re.search(r"isa = (\w+);", body).group(1) for key, body in objects}
    bodies = dict(objects)
    products = {
        key: re.search(r"productName = \"?([^\";]+)\"?;", body).group(1)
        for key, body in objects if isa[key] == "XCSwiftPackageProductDependency"
    }
    for name in sorted(set(products.values()) - LINKABLE_PRODUCTS):
        yield f"the Xcode project must not depend on package product {name}"
    for key in bodies:
        if isa[key] == "XCRemoteSwiftPackageReference":
            yield "the Xcode project must not reference a remote package"
        if isa[key] == "XCLocalSwiftPackageReference" and not re.search(r"relativePath = \.;", bodies[key]):
            yield "the Xcode project's only package must be the one at the repository root"
    targets = {}
    for key, body in objects:
        if isa[key] != "PBXNativeTarget":
            continue
        name = re.search(r"\bname = \"?([^\";]+)\"?;", body).group(1)
        listed = re.search(r"packageProductDependencies = \((.*?)\);", body, re.S)
        targets[name] = {products.get(ref, ref) for ref in re.findall(r"\w{24}", listed.group(1) if listed else "")}
    if set(targets) != PROJECT_TARGETS:
        yield f"the Xcode project's targets must be {sorted(PROJECT_TARGETS)}; got {sorted(targets)}"
    if targets.get("RunPlayStudio") != LINKABLE_PRODUCTS:
        yield f"RunPlayStudio must link exactly {sorted(LINKABLE_PRODUCTS)}"
    if not targets.get("RunPlayStudioTests", set()) <= LINKABLE_PRODUCTS:
        yield f"RunPlayStudioTests may link only {sorted(LINKABLE_PRODUCTS)}"


def project_self_test():
    project = PROJECT.read_text(encoding="utf-8")
    if list(project_violations(project)) != []:
        raise ValueError(f"the committed project fails its own check: {list(project_violations(project))}")
    engine = project.replace("productName = RunPlayPlatform;", f"productName = {ENGINE};", 1)
    if f"the Xcode project must not depend on package product {ENGINE}" not in list(project_violations(engine)):
        raise ValueError("an engine product in the Xcode project was not reported")
    remote = project.replace("isa = XCLocalSwiftPackageReference;", "isa = XCRemoteSwiftPackageReference;", 1)
    if "the Xcode project must not reference a remote package" not in list(project_violations(remote)):
        raise ValueError("a remote package in the Xcode project was not reported")


def c_family_sources(directory):
    for path, folders, filenames in os.walk(directory):
        folders[:] = sorted(folder for folder in folders if not folder.startswith("."))
        for filename in sorted(filenames):
            if os.path.splitext(filename)[1] in C_FAMILY_SUFFIXES:
                yield Path(path) / filename


def language_violations(description, root):
    """Reject every non-Swift target and every C-family source.

    `description` is the output of `swift package describe --type json`. It
    names each target's module type, so a C, C++, Objective-C, system-library
    or binary target fails here whatever language standard it uses.
    """
    directories = list(EXTRA_SOURCE_DIRECTORIES)
    for target in description["targets"]:
        if target.get("module_type") != "SwiftTarget":
            yield f"target {target['name']} must be a Swift target, not {target.get('module_type')}"
        directories.append(target["path"])
    seen = set()
    for directory in directories:
        for path in c_family_sources(root / directory):
            if path not in seen:
                seen.add(path)
                yield f"{path.relative_to(root)}: C-family source in a pure Swift package"


def language_self_test():
    def swift(name, path):
        return {"name": name, "module_type": "SwiftTarget", "path": path}

    def other(name, module_type, path):
        return {"name": name, "module_type": module_type, "path": path}

    cases = (
        ("pure Swift package", [swift("App", "Sources/App")], {"Sources/App/App.swift"}, []),
        ("C target", [swift("App", "Sources/App"), other("CLib", "ClangTarget", "Sources/CLib")],
         {"Sources/App/App.swift", "Sources/CLib/lib.c", "Sources/CLib/include/lib.h"},
         ["target CLib must be a Swift target, not ClangTarget",
          "Sources/CLib/lib.c: C-family source in a pure Swift package",
          "Sources/CLib/include/lib.h: C-family source in a pure Swift package"]),
        ("C++ target", [other("CxxLib", "ClangTarget", "Sources/CxxLib")],
         {"Sources/CxxLib/kernel.cpp", "Sources/CxxLib/include/kernel.hpp"},
         ["target CxxLib must be a Swift target, not ClangTarget",
          "Sources/CxxLib/kernel.cpp: C-family source in a pure Swift package",
          "Sources/CxxLib/include/kernel.hpp: C-family source in a pure Swift package"]),
        ("system-library target", [other("CSystem", "SystemLibraryTarget", "Sources/CSystem")],
         {"Sources/CSystem/module.modulemap"},
         ["target CSystem must be a Swift target, not SystemLibraryTarget"]),
        ("stray header in a Swift target", [swift("App", "Sources/App")],
         {"Sources/App/App.swift", "Sources/App/Bridge.h"},
         ["Sources/App/Bridge.h: C-family source in a pure Swift package"]),
        ("assembly in the consumer smoke package", [swift("App", "Sources/App")],
         {"Sources/App/App.swift", "Tests/PackageConsumerSmoke/Sources/Smoke/entry.S"},
         ["Tests/PackageConsumerSmoke/Sources/Smoke/entry.S: C-family source in a pure Swift package"]),
    )
    for name, targets, files, expected in cases:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for relative in files:
                (root / relative).parent.mkdir(parents=True, exist_ok=True)
                (root / relative).write_text("", encoding="utf-8")
            actual = list(language_violations({"targets": targets}, root))
        if actual != expected:
            raise ValueError(f"{name}: expected {expected!r}; got {actual!r}")


def self_test():
    cases = (
        ("engine-foundation.swift", "RunPlayEngine/Sources/Kernel.swift", "engine cannot import Foundation"),
        ("platform-engine.swift", "RunPlayPlatform/Sources/Adapter.swift", "unauthorized RunPlayEngine import"),
        ("core-unqualified.swift", "RunPlayCore/Sources/Adapter.swift", "unauthorized RunPlayEngine import"),
        ("core-exported.swift", "RunPlayCore/Sources/Adapter.swift", "unauthorized RunPlayEngine import"),
        ("core-exported-modifiers.swift", "RunPlayCore/Sources/Adapter.swift", "unauthorized RunPlayEngine import"),
        ("core-commented-and-raw.swift", "RunPlayCore/Sources/Adapter.swift", None),
        ("core-golden.swift", "RunPlayCore/Tests/RunPlayCoreTests/GeodesyGoldenTests.swift", None),
        ("core-golden.swift", "RunPlayCore/Tests/RunPlayCoreTests/GeodesyTests.swift",
         "unauthorized RunPlayEngine import"),
        ("core-golden.swift", "RunPlayCore/Tests/OtherTests/GeodesyGoldenTests.swift",
         "unauthorized RunPlayEngine import"),
        ("core-golden.swift", "RunPlayPlatform/Tests/RunPlayPlatformTests/GeodesyGoldenTests.swift",
         "unauthorized RunPlayEngine import"),
        ("core-exported.swift", "RunPlayCore/Tests/RunPlayCoreTests/GeodesyGoldenTests.swift",
         "unauthorized RunPlayEngine import"),
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
    language_self_test()
    project_self_test()


def main():
    self_test()
    errors = []
    # --graph-only skips the source scan. The macOS lane uses it: the scan
    # runs once on Linux, but only macOS declares the Platform target, so only
    # macOS can check its edges. Studio's sources are scanned here too; its
    # target edges come from the Xcode project.
    graph_only = sys.argv[1:] == ["--graph-only"]
    if sys.argv[1:] and not graph_only:
        print("usage: validate-swift-engine-boundaries.py [--graph-only]", file=sys.stderr)
        return 2
    owners = () if graph_only else (
        "RunPlayEngine", "RunPlayCore", "RunPlayPlatform",
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
    # Both modes check the target languages: only macOS declares the Platform
    # target, so the graph-only lane is the one that sees it.
    description = subprocess.check_output(["swift", "package", "describe", "--type", "json"], cwd=ROOT, text=True)
    errors.extend(language_violations(json.loads(description), ROOT))
    # Both modes check the Xcode project: RunPlayStudio and its tests are its
    # targets, outside the SwiftPM graph on every host.
    errors.extend(project_violations(PROJECT.read_text(encoding="utf-8")))
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("Swift engine target graph verified" if graph_only
          else "Swift engine import boundaries and target graph verified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
