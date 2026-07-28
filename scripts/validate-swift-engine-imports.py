#!/usr/bin/env python3
"""Find RunPlayEngineCpp imports with a comment- and string-aware Swift lexer."""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path
import re
import subprocess
import sys
import tempfile


ACCESS_MODIFIERS = {
    "fileprivate",
    "internal",
    "open",
    "package",
    "private",
    "public",
}
IMPORT_KINDS = {
    "class",
    "enum",
    "func",
    "let",
    "operator",
    "protocol",
    "struct",
    "typealias",
    "var",
}
SWIFT_LINE_BREAKS = {"\n", "\r", "\v", "\f", "\u0085", "\u2028", "\u2029"}


@dataclass(frozen=True)
class Token:
    value: str
    line: int
    is_escaped_identifier: bool = False


@dataclass(frozen=True)
class EngineImport:
    line: int
    access: str | None
    kind: str | None
    path: tuple[str, ...]
    has_attribute: bool
    has_escaped_identifier: bool


@dataclass(frozen=True)
class CompilerEngineImport:
    line: int
    kind: str | None
    path: tuple[str, ...]
    is_exported: bool


def line_break_length(source: str, index: int) -> int:
    if index >= len(source) or source[index] not in SWIFT_LINE_BREAKS:
        return 0
    if source.startswith("\r\n", index):
        return 2
    return 1


def count_line_breaks(source: str) -> int:
    count = 0
    index = 0
    while index < len(source):
        break_length = line_break_length(source, index)
        if break_length:
            count += 1
            index += break_length
        else:
            index += 1
    return count


def compiler_engine_imports(
    files: list[Path],
    swiftc: str,
) -> dict[Path, list[CompilerEngineImport]]:
    """Use Swift's parser as the authority for which tokens are imports."""
    def parse_file(path: Path) -> list[CompilerEngineImport]:
        # Import discovery does not need access evaluation, which can crash the
        # Swift 6.3.3 AST dumper on otherwise valid protocol conformances.
        command = [
            swiftc,
            "-frontend",
            "-dump-parse",
            "-disable-access-control",
            "-swift-version",
            "6",
            str(path),
        ]
        try:
            process = subprocess.Popen(
                command,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                encoding="utf-8",
                errors="replace",
            )
        except OSError as error:
            raise RuntimeError(
                f"could not execute Swift parser for {path}: {error}"
            ) from error

        imports: list[CompilerEngineImport] = []
        diagnostics: list[str] = []
        assert process.stdout is not None
        for output_line in process.stdout:
            if "(import_decl " not in output_line:
                if "error:" in output_line:
                    diagnostics.append(output_line.rstrip())
                continue

            module_match = re.search(r'\bmodule="([^"]+)"', output_line)
            range_match = re.search(r"\brange=\[(.*?) - ", output_line)
            if module_match is None or range_match is None:
                continue

            module_path = tuple(module_match.group(1).split("."))
            if not module_path or module_path[0] != "RunPlayEngineCpp":
                continue

            try:
                _, line_text, _ = range_match.group(1).rsplit(":", 2)
                line = int(line_text)
            except ValueError as error:
                process.kill()
                process.wait()
                raise RuntimeError(
                    "Swift parser reported an engine import at an unknown "
                    f"source location: {range_match.group(1)}"
                ) from error

            kind_match = re.search(
                r"\bkind=([A-Za-z_][A-Za-z0-9_]*)",
                output_line,
            )
            imports.append(
                CompilerEngineImport(
                    line=line,
                    kind=None if kind_match is None else kind_match.group(1),
                    path=module_path,
                    is_exported=(
                        re.search(
                            r"(?:^|\s)exported(?:\s|$)",
                            output_line,
                        )
                        is not None
                    ),
                )
            )

        return_code = process.wait()
        if return_code != 0:
            detail = "\n".join(diagnostics[:10])
            raise RuntimeError(
                f"Swift parser could not inspect {path} "
                f"(exit status {return_code})"
                + (f":\n{detail}" if detail else "")
            )
        return imports

    worker_count = max(1, min(8, len(files)))
    with ThreadPoolExecutor(max_workers=worker_count) as executor:
        parsed = executor.map(parse_file, files)
        return {path: imports for path, imports in zip(files, parsed)}


def skip_quoted_source(source: str, index: int) -> int | None:
    hash_count = 0
    while index + hash_count < len(source) and source[index + hash_count] == "#":
        hash_count += 1

    quote_index = index + hash_count
    if quote_index >= len(source) or source[quote_index] != '"':
        return None

    quote = '"""' if source.startswith('"""', quote_index) else '"'
    content_index = quote_index + len(quote)
    closing = quote + ("#" * hash_count)

    while content_index < len(source):
        if source.startswith(closing, content_index):
            return content_index + len(closing)
        if hash_count == 0 and source[content_index] == "\\":
            content_index += 2
        else:
            content_index += 1
    return len(source)


def skip_regex_source(
    source: str,
    index: int,
    tokens: list[Token],
) -> int | None:
    hash_count = 0
    while index + hash_count < len(source) and source[index + hash_count] == "#":
        hash_count += 1

    slash_index = index + hash_count
    if slash_index >= len(source) or source[slash_index] != "/":
        return None
    if hash_count == 0:
        if source.startswith("//", slash_index) or source.startswith(
            "/*",
            slash_index,
        ):
            return None
        expression_prefixes = {
            "!",
            "&&",
            "(",
            ",",
            ":",
            ";",
            "=",
            "?",
            "[",
            "{",
            "case",
            "in",
            "return",
            "throw",
            "where",
            "||",
        }
        if tokens and tokens[-1].value not in expression_prefixes:
            return None

    closing = "/" + ("#" * hash_count)
    cursor = slash_index + 1
    in_character_class = False
    while cursor < len(source):
        if source[cursor] == "\\":
            cursor += 2
            continue
        if source[cursor] == "[":
            in_character_class = True
            cursor += 1
            continue
        if source[cursor] == "]" and in_character_class:
            in_character_class = False
            cursor += 1
            continue
        if not in_character_class and source.startswith(closing, cursor):
            return cursor + len(closing)
        cursor += 1
    return None


def swift_tokens(source: str) -> list[Token]:
    tokens: list[Token] = []
    index = 0
    line = 1

    while index < len(source):
        if source.startswith("//", index):
            comment_end = index + 2
            while (
                comment_end < len(source)
                and not line_break_length(source, comment_end)
            ):
                comment_end += 1
            index = comment_end
            continue
        if source.startswith("/*", index):
            depth = 1
            end = index + 2
            while end < len(source) and depth > 0:
                if source.startswith("/*", end):
                    depth += 1
                    end += 2
                elif source.startswith("*/", end):
                    depth -= 1
                    end += 2
                else:
                    end += 1
            line += count_line_breaks(source[index:end])
            index = end
            continue

        quoted_end = skip_quoted_source(source, index)
        if quoted_end is not None:
            line += count_line_breaks(source[index:quoted_end])
            index = quoted_end
            continue
        regex_end = skip_regex_source(source, index, tokens)
        if regex_end is not None:
            line += count_line_breaks(source[index:regex_end])
            index = regex_end
            continue

        character = source[index]
        break_length = line_break_length(source, index)
        if break_length:
            line += 1
            index += break_length
            continue
        if character.isspace():
            index += 1
            continue
        if character == "`":
            closing_index = source.find("`", index + 1)
            end = len(source) if closing_index == -1 else closing_index + 1
            value_end = end if closing_index == -1 else closing_index
            tokens.append(
                Token(
                    source[index + 1:value_end],
                    line,
                    is_escaped_identifier=True,
                )
            )
            line += count_line_breaks(source[index:end])
            index = end
            continue
        if character == "_" or character.isalpha():
            end = index + 1
            while end < len(source):
                candidate = source[end]
                if candidate != "_" and not candidate.isalnum():
                    break
                end += 1
            tokens.append(Token(source[index:end], line))
            index = end
            continue
        if source.startswith(("&&", "||"), index):
            tokens.append(Token(source[index:index + 2], line))
            index += 2
            continue
        if character in {
            "!",
            "(",
            ")",
            ",",
            ".",
            ":",
            ";",
            "=",
            "?",
            "@",
            "[",
            "]",
            "{",
            "}",
        }:
            tokens.append(Token(character, line))
        index += 1

    return tokens


def attached_attribute_before(tokens: list[Token], index: int) -> bool:
    if index < 0:
        return False
    if (
        index >= 1
        and tokens[index - 1].value == "@"
        and tokens[index].value not in {"@", ".", "(", ")", ";"}
    ):
        return True
    if tokens[index].value != ")":
        return False

    depth = 1
    cursor = index - 1
    while cursor >= 0:
        if tokens[cursor].value == ")":
            depth += 1
        elif tokens[cursor].value == "(":
            depth -= 1
            if depth == 0:
                return (
                    cursor >= 2
                    and tokens[cursor - 2].value == "@"
                    and tokens[cursor - 1].value
                    not in {"@", ".", "(", ")", ";"}
                )
        cursor -= 1
    return False


def engine_imports(source: str) -> list[EngineImport]:
    tokens = swift_tokens(source)
    imports: list[EngineImport] = []

    for index, token in enumerate(tokens):
        if token.value != "import" or token.is_escaped_identifier:
            continue

        cursor = index + 1
        kind: str | None = None
        if cursor < len(tokens) and tokens[cursor].value in IMPORT_KINDS:
            kind = tokens[cursor].value
            cursor += 1
        if cursor >= len(tokens) or tokens[cursor].value != "RunPlayEngineCpp":
            continue

        path = [tokens[cursor].value]
        has_escaped_identifier = tokens[cursor].is_escaped_identifier
        cursor += 1
        while (
            cursor + 1 < len(tokens)
            and tokens[cursor].value == "."
            and tokens[cursor + 1].value
            not in {"@", ".", "(", ")", ";"}
        ):
            path.append(tokens[cursor + 1].value)
            has_escaped_identifier = (
                has_escaped_identifier
                or tokens[cursor + 1].is_escaped_identifier
            )
            cursor += 2

        prefix_index = index - 1
        access: str | None = None
        if prefix_index >= 0 and tokens[prefix_index].value in ACCESS_MODIFIERS:
            access = tokens[prefix_index].value
            prefix_index -= 1

        imports.append(
            EngineImport(
                line=token.line,
                access=access,
                kind=kind,
                path=tuple(path),
                has_attribute=attached_attribute_before(tokens, prefix_index),
                has_escaped_identifier=has_escaped_identifier,
            )
        )

    return imports


def contains_engine_module_token(source: str) -> bool:
    """Return whether this source needs compiler confirmation."""
    return any(
        token.value == "RunPlayEngineCpp"
        for token in swift_tokens(source)
    )


def validate_sources(
    sources: dict[Path, str],
    allowed_prefix: Path,
    compiler_imports: dict[Path, list[CompilerEngineImport]] | None = None,
) -> tuple[list[str], list[Path]]:
    errors: list[str] = []
    allowed_files: list[Path] = []
    allowed_prefix = allowed_prefix.resolve()
    import_count = 0

    for path, source in sources.items():
        lexical_imports = engine_imports(source)
        if compiler_imports is None:
            detected_imports = [
                (
                    CompilerEngineImport(
                        line=engine_import.line,
                        kind=engine_import.kind,
                        path=engine_import.path,
                        is_exported=False,
                    ),
                    engine_import,
                )
                for engine_import in lexical_imports
            ]
        else:
            detected_imports: list[
                tuple[CompilerEngineImport, EngineImport | None]
            ] = []
            used_lexical_indices: set[int] = set()
            for compiler_import in compiler_imports.get(path, []):
                matching_indices = [
                    index
                    for index, lexical_import in enumerate(lexical_imports)
                    if (
                        lexical_import.line == compiler_import.line
                        and lexical_import.path == compiler_import.path
                    )
                ]
                lexical_import = None
                if len(matching_indices) == 1:
                    matching_index = matching_indices[0]
                    used_lexical_indices.add(matching_index)
                    lexical_import = lexical_imports[matching_index]
                detected_imports.append((compiler_import, lexical_import))

            for index, lexical_import in enumerate(lexical_imports):
                if index in used_lexical_indices:
                    continue
                detected_imports.append(
                    (
                        CompilerEngineImport(
                            line=lexical_import.line,
                            kind=lexical_import.kind,
                            path=lexical_import.path,
                            is_exported=False,
                        ),
                        lexical_import,
                    )
                )

        for detected_import, engine_import in detected_imports:
            import_count += 1
            resolved_path = path.resolve()
            is_allowed_path = (
                resolved_path == allowed_prefix
                or allowed_prefix in resolved_path.parents
            )
            if not is_allowed_path:
                errors.append(
                    f"{path}:{detected_import.line}: RunPlayEngineCpp import is "
                    "outside RunPlayCore/Sources/Interop"
                )
                continue

            if engine_import is None:
                errors.append(
                    f"{path}:{detected_import.line}: compiler-confirmed engine "
                    "import could not be matched to one safe lexical declaration"
                )
                continue

            if (
                engine_import.access != "internal"
                or detected_import.kind is not None
                or detected_import.path != ("RunPlayEngineCpp",)
                or detected_import.is_exported
                or engine_import.has_attribute
                or engine_import.has_escaped_identifier
            ):
                errors.append(
                    f"{path}:{engine_import.line}: engine imports in Interop "
                    "must be exactly unscoped, unattributed, and unescaped "
                    "'internal import RunPlayEngineCpp'"
                )
                continue
            allowed_files.append(path)

    if import_count == 0:
        errors.append("no Swift file imports RunPlayEngineCpp")
    return errors, sorted(set(allowed_files), key=lambda path: str(path))


def run_self_test(swiftc: str) -> int:
    allowed_prefix = Path("/repo/RunPlayCore/Sources/Interop")
    valid_sources = {
        allowed_prefix / "Bridge.swift": (
            "internal import\n"
            "RunPlayEngineCpp\n"
            'let text = "import RunPlayEngineCpp"\n'
            "// public import RunPlayEngineCpp\n"
        )
    }
    errors, _ = validate_sources(valid_sources, allowed_prefix)
    if errors:
        print("Swift import validator rejected its valid fixture", file=sys.stderr)
        return 1

    adversarial_sources = {
        "exported multiline import": {
            allowed_prefix / "Bridge.swift": (
                "@_exported\ninternal import RunPlayEngineCpp\n"
            )
        },
        "preconcurrency multiline import": {
            allowed_prefix / "Bridge.swift": (
                "@preconcurrency\ninternal import RunPlayEngineCpp\n"
            )
        },
        "scoped multiline import": {
            allowed_prefix / "Bridge.swift": (
                "internal import struct\nRunPlayEngineCpp.RouteInputSample\n"
            )
        },
        "wrong layer": {
            Path("/repo/RunPlayPlatform/Sources/Escape.swift"): (
                "internal import\nRunPlayEngineCpp\n"
            )
        },
        "backticked module in wrong layer": {
            Path("/repo/RunPlayStudio/Sources/Escape.swift"): (
                "internal import `RunPlayEngineCpp`\n"
            )
        },
        "backticked module in allowed adapter": {
            allowed_prefix / "Bridge.swift": (
                "internal import `RunPlayEngineCpp`\n"
            )
        },
    }
    for name, sources in adversarial_sources.items():
        errors, _ = validate_sources(sources, allowed_prefix)
        if not errors:
            print(
                f"Swift import validator missed adversarial case: {name}",
                file=sys.stderr,
            )
            return 1

    compiler_candidate_fixtures = {
        "active import": "internal import RunPlayEngineCpp\n",
        "inactive import": (
            "#if false\ninternal import RunPlayEngineCpp\n#endif\n"
        ),
        "comment and literal decoys": (
            "// RunPlayEngineCpp\n"
            'let text = "RunPlayEngineCpp"\n'
            "let pattern = #/RunPlayEngineCpp/#\n"
        ),
    }
    selected_candidate_names = {
        name
        for name, source in compiler_candidate_fixtures.items()
        if contains_engine_module_token(source)
    }
    if selected_candidate_names != {"active import", "inactive import"}:
        print(
            "Swift import validator selected the wrong compiler candidates: "
            f"{sorted(selected_candidate_names)}",
            file=sys.stderr,
        )
        return 1

    with tempfile.TemporaryDirectory(
        prefix="runplay-swift-import-validator-"
    ) as temporary_directory:
        root = Path(temporary_directory)
        compiler_allowed_prefix = root / "RunPlayCore/Sources/Interop"
        compiler_allowed_prefix.mkdir(parents=True)
        platform_sources = root / "RunPlayPlatform/Sources"
        platform_sources.mkdir(parents=True)
        studio_sources = root / "RunPlayStudio/Sources"
        studio_sources.mkdir(parents=True)

        valid_path = compiler_allowed_prefix / "Bridge.swift"
        unicode_comment_path = platform_sources / "UnicodeComment.swift"
        carriage_return_path = platform_sources / "CarriageReturn.swift"
        raw_regex_path = studio_sources / "RawRegex.swift"
        conditional_path = studio_sources / "Conditional.swift"
        decoy_path = platform_sources / "Decoys.swift"
        compiler_sources = {
            valid_path: "internal import RunPlayEngineCpp\n",
            unicode_comment_path: (
                "// comment\u2028internal import RunPlayEngineCpp\n"
            ),
            carriage_return_path: (
                "// comment\rinternal import RunPlayEngineCpp\n"
            ),
            raw_regex_path: (
                "let routePattern = #/https://example/#; "
                "internal import RunPlayEngineCpp\n"
            ),
            conditional_path: (
                "#if canImport(RunPlayEngineCpp)\n"
                "internal import RunPlayEngineCpp\n"
                "#endif\n"
            ),
            decoy_path: (
                "let importPattern = #/internal import RunPlayEngineCpp/#\n"
                "func consume(import value: Any) {}\n"
                "consume(import: RunPlayEngineCpp())\n"
                "func fail() throws { "
                "throw /internal import RunPlayEngineCpp/ }\n"
            ),
        }
        for path, source in compiler_sources.items():
            path.write_text(source, encoding="utf-8")

        try:
            parsed_imports = compiler_engine_imports(
                list(compiler_sources),
                swiftc,
            )
        except RuntimeError as error:
            print(f"Swift parser validator self-test failed: {error}", file=sys.stderr)
            return 1

        if parsed_imports[decoy_path] or engine_imports(
            compiler_sources[decoy_path]
        ):
            print(
                "Swift parser validator treated regex or argument-label "
                "decoys as imports",
                file=sys.stderr,
            )
            return 1
        if (
            len(parsed_imports[valid_path]) != 1
            or parsed_imports[unicode_comment_path]
            or len(parsed_imports[carriage_return_path]) != 1
            or len(parsed_imports[raw_regex_path]) != 1
            or parsed_imports[conditional_path]
        ):
            print(
                "Swift parser validator missed a compiler-confirmed import: "
                f"valid={len(parsed_imports[valid_path])}, "
                f"unicode={len(parsed_imports[unicode_comment_path])}, "
                f"carriage={len(parsed_imports[carriage_return_path])}, "
                f"regex={len(parsed_imports[raw_regex_path])}, "
                f"conditional={len(parsed_imports[conditional_path])}",
                file=sys.stderr,
            )
            return 1

        errors, _ = validate_sources(
            compiler_sources,
            compiler_allowed_prefix,
            parsed_imports,
        )
        if not any(
            str(unicode_comment_path) in error for error in errors
        ) or not any(
            str(carriage_return_path) in error for error in errors
        ) or not any(
            str(raw_regex_path) in error for error in errors
        ) or not any(str(conditional_path) in error for error in errors):
            print(
                "Swift parser validator did not reject hidden wrong-layer imports",
                file=sys.stderr,
            )
            return 1
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--swiftc", default="swiftc")
    parser.add_argument("--allowed-prefix", type=Path)
    parser.add_argument("files", nargs="*", type=Path)
    args = parser.parse_args()

    if args.self_test:
        return run_self_test(args.swiftc)
    if args.allowed_prefix is None:
        parser.error("--allowed-prefix is required outside --self-test")

    sources = {
        path: path.read_text(encoding="utf-8")
        for path in args.files
    }
    compiler_candidates = [
        path
        for path, source in sources.items()
        if contains_engine_module_token(source)
    ]
    try:
        parsed_imports = compiler_engine_imports(compiler_candidates, args.swiftc)
    except RuntimeError as error:
        print(error, file=sys.stderr)
        return 1
    errors, allowed_files = validate_sources(
        sources,
        args.allowed_prefix,
        parsed_imports,
    )
    for error in errors:
        print(error, file=sys.stderr)
    if errors:
        return 1
    for path in allowed_files:
        print(path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
