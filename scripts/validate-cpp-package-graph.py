#!/usr/bin/env python3
"""Validate the SwiftPM dependency edge into RunPlayEngineCpp."""

import json
import sys
from typing import Any, Dict, List, Optional, Set


ENGINE_TARGET = "RunPlayEngineCpp"
ALLOWED_DIRECT_DEPENDENTS = {"RunPlayCore"}


def dependency_name(dependency: Dict[str, Any]) -> Optional[str]:
    for kind in ("byName", "target", "product"):
        value = dependency.get(kind)
        if isinstance(value, list) and value and isinstance(value[0], str):
            return value[0]
    return None


def main() -> int:
    try:
        package = json.load(sys.stdin)
    except (json.JSONDecodeError, TypeError) as error:
        print(f"invalid swift package JSON: {error}", file=sys.stderr)
        return 1

    targets = package.get("targets")
    if not isinstance(targets, list):
        print("swift package JSON has no targets array", file=sys.stderr)
        return 1

    direct_dependents: Set[str] = set()
    target_names: Set[str] = set()

    for target in targets:
        if not isinstance(target, dict) or not isinstance(target.get("name"), str):
            print("swift package JSON contains an invalid target", file=sys.stderr)
            return 1

        target_name = target["name"]
        target_names.add(target_name)
        dependencies = target.get("dependencies", [])
        if not isinstance(dependencies, list):
            print(f"target {target_name} has invalid dependencies", file=sys.stderr)
            return 1

        if any(
            isinstance(dependency, dict)
            and dependency_name(dependency) == ENGINE_TARGET
            for dependency in dependencies
        ):
            direct_dependents.add(target_name)

    errors: List[str] = []
    if ENGINE_TARGET not in target_names:
        errors.append(f"missing target {ENGINE_TARGET}")

    missing = ALLOWED_DIRECT_DEPENDENTS - direct_dependents
    if missing:
        errors.append(
            f"required direct dependents missing: {', '.join(sorted(missing))}"
        )

    forbidden = direct_dependents - ALLOWED_DIRECT_DEPENDENTS
    if forbidden:
        errors.append(
            f"unexpected direct dependents: {', '.join(sorted(forbidden))}"
        )

    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1

    print(
        "SwiftPM graph allows only RunPlayCore to depend directly on "
        "RunPlayEngineCpp"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
