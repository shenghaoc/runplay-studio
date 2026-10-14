#!/usr/bin/env python3
"""Check (or update) the String Catalogs against compiler-extracted strings.

Invoked by scripts/check-localization.sh after a build that passed
`-emit-localized-strings`; see that script for the workflow. Python 3 standard
library only.

For every module catalog it:

1. Syncs a temporary copy with the module's .stringsdata files through
   `xcrun xcstringstool sync` — the same merge Xcode performs — and reports
   keys the sync had to add (missing from the catalog) and keys it marked
   stale (no longer in source).
2. Checks every live key that needs translation has a translated zh-Hans and
   zh-Hant value whose format placeholders match the English source.

With --update the synced catalogs are written back instead of failing on
missing or stale keys (stale keys are removed), so a developer can add the
new keys' translations; the translation check still runs and still fails.
"""

import argparse
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

# Catalog per Swift module, keyed by the source directory whose strings it owns.
MODULES = [
    ("RunPlayCore", "RunPlayCore/Sources/", "RunPlayCore/Localization/Localizable.xcstrings"),
    ("RunPlayPlatform", "RunPlayPlatform/Sources/", "RunPlayPlatform/Localization/Localizable.xcstrings"),
    ("RunPlayStudio", "RunPlayStudio/Sources/", "RunPlayStudio/Localization/Localizable.xcstrings"),
]
TRANSLATED_LANGUAGES = ["zh-Hans", "zh-Hant"]
# printf-style specifiers as String(localized:) and catalogs write them:
# optional positional index, flags/width/precision, length, conversion.
SPECIFIER = re.compile(r"%(?:(\d+)\$)?[-+ #0]*\d*(?:\.\d+)?(hh|h|ll|l|q|z|t|j|L)?([@dDiuUxXoOfFeEgGcCsSpaA%])")


def specifiers(text):
    """Sorted conversion families, ignoring argument positions and %%.

    `%d`, `%ld`, and `%lld` print the same integer, and a translation may
    reorder arguments with `%1$@`-style positions, so only the multiset of
    conversion families has to match the source.
    """
    families = []
    for match in SPECIFIER.finditer(text):
        conversion = match.group(3)
        if conversion == "%":
            continue
        if conversion in "dDiuU":
            families.append("integer")
        elif conversion in "fFeEgGaA":
            families.append("float")
        else:
            families.append(conversion)
    return sorted(families)


def load_stringsdata(paths, repo_root):
    """Map module name -> list of .stringsdata paths, newest per source file."""
    by_source = {}
    for path in paths:
        try:
            with open(path, encoding="utf-8") as handle:
                data = json.load(handle)
        except (OSError, ValueError):
            continue
        source = os.path.realpath(data.get("source", ""))
        if not os.path.isfile(source):
            continue  # A deleted source file's leftover from an incremental build.
        previous = by_source.get(source)
        if previous is None or os.path.getmtime(path) > os.path.getmtime(previous):
            by_source[source] = path
    grouped = {name: [] for name, _, _ in MODULES}
    real_root = os.path.realpath(repo_root)
    for source, path in by_source.items():
        relative = os.path.relpath(source, real_root)
        for name, prefix, _ in MODULES:
            if relative.startswith(prefix):
                grouped[name].append(path)
    return grouped


def needs_translation(entry):
    return entry.get("shouldTranslate", True) is not False and entry.get("extractionState") != "stale"


def unit_values(localization):
    """All (label, stringUnit) pairs of one language, including variations."""
    units = []
    if "stringUnit" in localization:
        units.append(("", localization["stringUnit"]))
    for kind, cases in localization.get("variations", {}).items():
        for case, payload in cases.items():
            for label, unit in unit_values(payload):
                units.append((f"{kind}.{case}{label}", unit))
    return units


def source_texts(key, entry):
    """English texts a translation must match.

    A semantic key ("route_group.default_name") carries its English as the
    en value; an English-text key is its own source. An en entry built from
    plural substitutions ("%#@runs@") keeps its arguments in the key, so the
    key is the source there too.
    """
    english = entry.get("localizations", {}).get("en")
    if english and "substitutions" not in english:
        values = [unit.get("value", "") for _, unit in unit_values(english)]
        if values:
            return values
    return [key]


def check_translations(name, catalog):
    problems = []
    for key, entry in sorted(catalog.get("strings", {}).items()):
        if not needs_translation(entry):
            continue
        english = source_texts(key, entry)
        # The last English unit is the plural "other" form (or the only one).
        expected = specifiers(english[-1])
        for text in english:
            # An en "one" form may spell its count ("One run"), so it may drop
            # placeholders, never add them.
            if not set(specifiers(text)) <= set(expected):
                problems.append(f"{name}: en variants disagree on placeholders: {key!r}")
        for language in TRANSLATED_LANGUAGES:
            localization = entry.get("localizations", {}).get(language)
            if not localization:
                problems.append(f"{name}: missing {language}: {key!r}")
                continue
            units = unit_values(localization)
            if not units:
                problems.append(f"{name}: empty {language}: {key!r}")
                continue
            for label, unit in units:
                state = unit.get("state")
                value = unit.get("value", "")
                where = f"{language}{'/' + label if label else ''}"
                if state != "translated":
                    problems.append(f"{name}: {where} is {state!r}, not translated: {key!r}")
                if not value.strip():
                    problems.append(f"{name}: {where} is blank: {key!r}")
                elif specifiers(value) != expected:
                    problems.append(
                        f"{name}: {where} placeholders {specifiers(value)} != source {expected}: {key!r}"
                    )
    return problems


def sync_catalog(catalog_path, stringsdata, work_dir):
    """Return (synced catalog dict, added keys, stale keys)."""
    with open(catalog_path, encoding="utf-8") as handle:
        before = json.load(handle)
    # xcstringstool matches tables by file name, so the copy keeps it.
    copy_dir = tempfile.mkdtemp(dir=work_dir)
    copy_path = os.path.join(copy_dir, os.path.basename(catalog_path))
    shutil.copyfile(catalog_path, copy_path)
    if stringsdata:
        subprocess.run(
            ["xcrun", "xcstringstool", "sync", copy_path, "--stringsdata", *stringsdata],
            check=True,
        )
    with open(copy_path, encoding="utf-8") as handle:
        after = json.load(handle)
    before_keys = set(before.get("strings", {}))
    added = sorted(set(after.get("strings", {})) - before_keys)
    stale = sorted(
        key for key, entry in after.get("strings", {}).items() if entry.get("extractionState") == "stale"
    )
    return after, added, stale


def english_units(entry):
    """Every English string unit of an entry, plural substitutions included."""
    english = entry.get("localizations", {}).get("en", {})
    units = [unit for _, unit in unit_values(english)]
    for substitution in english.get("substitutions", {}).values():
        units.extend(unit for _, unit in unit_values(substitution))
    return units


def promote_source_units(catalog):
    """Mark every English (source-language) string unit as translated."""
    for entry in catalog.get("strings", {}).values():
        for unit in english_units(entry):
            if unit.get("state") == "new":
                unit["state"] = "translated"


def write_catalog(path, catalog):
    """Write in xcstringstool's own layout so a later Xcode sync is a no-op:
    two-space indent, " : " separators, code-point key order, raw UTF-8, and
    empty objects opened over a blank line."""
    text = json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True, separators=(",", " : "))
    text = re.sub(r"^( *)(.*)\{\}(,?)$", lambda m: f"{m.group(1)}{m.group(2)}{{\n\n{m.group(1)}}}{m.group(3)}",
                  text, flags=re.MULTILINE)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo-root", required=True)
    parser.add_argument("--stringsdata-root", action="append", required=True,
                        help="directory searched recursively for .stringsdata (repeatable)")
    parser.add_argument("--update", action="store_true",
                        help="write synced catalogs back (adds new keys, drops stale ones)")
    args = parser.parse_args()

    paths = []
    for root in args.stringsdata_root:
        paths.extend(glob.glob(os.path.join(root, "**", "*.stringsdata"), recursive=True))
    grouped = load_stringsdata(paths, args.repo_root)

    failures = []
    with tempfile.TemporaryDirectory() as work_dir:
        for name, _, relative_catalog in MODULES:
            catalog_path = os.path.join(args.repo_root, relative_catalog)
            files = grouped[name]
            if not files:
                failures.append(f"{name}: no .stringsdata found — was the build run with -emit-localized-strings?")
                continue
            synced, added, stale = sync_catalog(catalog_path, files, work_dir)
            live = len(synced.get("strings", {})) - len(stale)
            print(f"{name}: {len(files)} source files, {live} live keys, "
                  f"{len(added)} missing, {len(stale)} stale")
            if args.update:
                for key in stale:
                    del synced["strings"][key]
                # xcstringstool sync records the English of a semantic or
                # multi-argument key as state "new", and compile leaves "new"
                # units out of the tables. English is the source language, so
                # its text is final as extracted.
                promote_source_units(synced)
                write_catalog(catalog_path, synced)
                if added or stale:
                    print(f"{name}: updated {relative_catalog} (+{len(added)} added, -{len(stale)} stale removed)")
            else:
                failures.extend(f"{name}: missing from catalog: {key!r}" for key in added)
                failures.extend(f"{name}: stale (not in source): {key!r}" for key in stale)
            failures.extend(check_translations(name, synced))
            failures.extend(
                f"{name}: English source unit still 'new' (run --update): {key!r}"
                for key, entry in synced.get("strings", {}).items()
                if entry.get("extractionState") != "stale"
                and any(unit.get("state") == "new" for unit in english_units(entry))
            )

    if failures:
        for line in failures:
            print(f"FAIL: {line}", file=sys.stderr)
        print(f"check-localization: {len(failures)} problem(s)", file=sys.stderr)
        if not args.update:
            print("Run scripts/check-localization.sh --update to sync the catalogs, "
                  "then translate the new keys.", file=sys.stderr)
        return 1
    print("check-localization: catalogs match source and are fully translated")
    return 0


if __name__ == "__main__":
    sys.exit(main())
