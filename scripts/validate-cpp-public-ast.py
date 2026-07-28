#!/usr/bin/env python3
"""Validate the Clang AST for RunPlayEngineCpp's public runplay namespace."""

from __future__ import annotations

import argparse
from pathlib import Path
import re
import sys


DECLARATION_KINDS = {
    "CXXConstructorDecl",
    "CXXConversionDecl",
    "CXXDestructorDecl",
    "CXXMethodDecl",
    "DecompositionDecl",
    "FieldDecl",
    "FunctionDecl",
    "IndirectFieldDecl",
    "NonTypeTemplateParmDecl",
    "ParmVarDecl",
    "TemplateTypeParmDecl",
    "TypeAliasDecl",
    "TypedefDecl",
    "VarDecl",
    "VarTemplateSpecializationDecl",
}
CALLABLE_DECLARATION_KINDS = {
    "CXXConstructorDecl",
    "CXXConversionDecl",
    "CXXDestructorDecl",
    "CXXMethodDecl",
    "FunctionDecl",
}
DISALLOWED_USING_DECLARATION_KINDS = {
    "NamespaceAliasDecl",
    "UsingDecl",
    "UsingDirectiveDecl",
    "UsingEnumDecl",
    "UsingShadowDecl",
}
ALLOWED_FUNCTION_TYPE = (
    "RouteBatchInspection "
    "(const RouteInputSample *, std::size_t) noexcept"
)
ALLOWED_PARAMETER_TYPE = "const RouteInputSample *"
CPP_TOKEN_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*|::|[{};]")
VECTOR_TYPE_RE = re.compile(
    r"(^|[^A-Za-z0-9_:])"
    r"(?:(?:[A-Za-z_][A-Za-z0-9_]*)::)*vector\s*<"
)


def declaration_kind(line: str) -> str | None:
    for kind in DECLARATION_KINDS:
        if re.search(rf"\b{kind}\b", line):
            return kind
    return None


def quoted_types(line: str) -> list[str]:
    return [
        re.sub(r"\s+", " ", value.strip())
        for value in re.findall(r"'([^']*)'", line)
    ]


def contains_declaration_kind(line: str, kinds: set[str]) -> bool:
    return any(re.search(rf"\b{kind}\b", line) for kind in kinds)


def is_implicit_declaration(line: str) -> bool:
    return re.search(r"(?:^|\s)implicit(?:\s|$)", line) is not None


def without_preprocessor_directives(source: str) -> str:
    kept_lines: list[str] = []
    in_directive = False
    for line in source.splitlines(keepends=True):
        is_directive = in_directive or line.lstrip().startswith("#")
        if is_directive:
            kept_lines.append("\n" if line.endswith("\n") else "")
            in_directive = line.rstrip().endswith("\\")
        else:
            kept_lines.append(line)
            in_directive = False
    return "".join(kept_lines)


def cpp_code_tokens(source: str) -> list[str]:
    source = without_preprocessor_directives(source)
    code: list[str] = []
    index = 0

    while index < len(source):
        if source.startswith("//", index):
            newline = source.find("\n", index + 2)
            index = len(source) if newline == -1 else newline
            continue
        if source.startswith("/*", index):
            end = source.find("*/", index + 2)
            index = len(source) if end == -1 else end + 2
            continue
        if source.startswith('R"', index):
            delimiter_end = source.find("(", index + 2)
            if delimiter_end != -1:
                delimiter = source[index + 2 : delimiter_end]
                closing = f"){delimiter}\""
                raw_end = source.find(closing, delimiter_end + 1)
                index = len(source) if raw_end == -1 else raw_end + len(closing)
                continue
        if source[index] in {'"', "'"}:
            quote = source[index]
            index += 1
            while index < len(source):
                if source[index] == "\\":
                    index += 2
                elif source[index] == quote:
                    index += 1
                    break
                else:
                    index += 1
            continue

        code.append(source[index])
        index += 1

    return CPP_TOKEN_RE.findall("".join(code))


def validate_namespace_envelope(path: Path) -> list[str]:
    tokens = cpp_code_tokens(path.read_text(encoding="utf-8"))
    errors: list[str] = []
    if "template" in tokens:
        return [f"{path}: public template declarations are unsupported"]
    depth = 0
    index = 0

    while index < len(tokens):
        token = tokens[index]
        if depth > 0:
            if token == "{":
                depth += 1
            elif token == "}":
                depth -= 1
            index += 1
            continue

        if token == ";":
            index += 1
            continue
        if token != "namespace":
            errors.append(
                f"{path}: public declaration outside namespace runplay "
                f"begins with {token!r}"
            )
            break

        index += 1
        if index >= len(tokens) or tokens[index] != "runplay":
            namespace_name = "<anonymous>" if index >= len(tokens) else tokens[index]
            errors.append(
                f"{path}: unsupported top-level public namespace {namespace_name!r}"
            )
            break
        index += 1

        while (
            index + 1 < len(tokens)
            and tokens[index] == "::"
            and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", tokens[index + 1])
        ):
            index += 2

        if index >= len(tokens) or tokens[index] != "{":
            errors.append(f"{path}: namespace runplay must use a braced definition")
            break
        depth = 1
        index += 1

    if depth != 0 and not errors:
        errors.append(f"{path}: unbalanced namespace or declaration braces")
    return errors


def validate_ast(ast_text: str) -> list[str]:
    errors: list[str] = []
    allowed_function_count = 0
    allowed_parameter_count = 0

    for raw_line in ast_text.splitlines():
        line = raw_line.strip()
        kind = declaration_kind(line)
        types = quoted_types(line)

        if contains_declaration_kind(
            line,
            DISALLOWED_USING_DECLARATION_KINDS,
        ):
            errors.append(
                f"public using or namespace-alias declaration is unsupported: "
                f"{line}"
            )

        if any(VECTOR_TYPE_RE.search(value) for value in types):
            errors.append(f"public declaration exposes std::vector: {line}")

        if (
            kind in CALLABLE_DECLARATION_KINDS
            and not is_implicit_declaration(line)
        ):
            if not types or "noexcept" not in types[0].split():
                errors.append(f"public callable is not noexcept: {line}")

        is_pointer_surface = (
            kind is not None
            or re.search(r"\bTemplateArgument\s+type\b", line) is not None
        )
        if not is_pointer_surface or not any("*" in value for value in types):
            continue

        is_allowed_function = (
            kind == "FunctionDecl"
            and re.search(r"\binspect_route_batch\b", line) is not None
            and types[0] == ALLOWED_FUNCTION_TYPE
        )
        is_allowed_parameter = (
            kind == "ParmVarDecl"
            and re.search(r"\bsamples\b", line) is not None
            and types[0] == ALLOWED_PARAMETER_TYPE
        )

        if is_allowed_function:
            allowed_function_count += 1
        elif is_allowed_parameter:
            allowed_parameter_count += 1
        else:
            errors.append(f"unsupported public raw pointer declaration: {line}")

    if allowed_function_count != 1:
        errors.append(
            "expected exactly one pointer-bearing inspect_route_batch declaration, "
            f"found {allowed_function_count}"
        )
    if allowed_parameter_count != 1:
        errors.append(
            "expected exactly one const RouteInputSample* samples parameter, "
            f"found {allowed_parameter_count}"
        )

    return errors


def run_self_test() -> int:
    valid_ast = "\n".join(
        [
            "FunctionDecl engine_info 'EngineInfo () noexcept'",
            "CXXMethodDecl explicit_method 'void () noexcept'",
            (
                "CXXMethodDecl implicit operator= "
                "'RouteInputSample &(RouteInputSample &&)'"
            ),
            (
                "FunctionDecl inspect_route_batch "
                f"'{ALLOWED_FUNCTION_TYPE}'"
            ),
            f"ParmVarDecl samples '{ALLOWED_PARAMETER_TYPE}'",
        ]
    )
    adversarial_cases = {
        "pointer alias": "TypeAliasDecl HiddenPointer 'RouteInputSample *'",
        "unnamed pointer parameter": "\n".join(
            [
                "FunctionDecl consume 'void (RouteInputSample *) noexcept'",
                "ParmVarDecl 'RouteInputSample *'",
            ]
        ),
        "qualified pointer": "TypeAliasDecl Qualified 'RouteInputSample *const'",
        "function pointer": "TypeAliasDecl Callback 'void (*)(RouteInputSample)'",
        "using-declared vector": "\n".join(
            [
                "UsingDecl std::vector",
                "FunctionDecl forbidden_vector 'vector<int> () noexcept'",
            ]
        ),
        "namespace-alias using-declared vector": "\n".join(
            [
                "NamespaceAliasDecl s 'std'",
                "UsingDecl s::vector",
                "UsingShadowDecl target ClassTemplate 'vector'",
            ]
        ),
        "using namespace": "UsingDirectiveDecl nominated Namespace 'std'",
        "throwing free function": (
            "FunctionDecl throwing_route_function "
            "'RouteBatchInspection ()'"
        ),
        "throwing public method": (
            "CXXMethodDecl throwing_method 'void ()'"
        ),
        "throwing public constructor": (
            "CXXConstructorDecl Extra 'void (int)'"
        ),
        "pointer non-type template parameter": (
            "NonTypeTemplateParmDecl Sample 'RouteInputSample *'"
        ),
        "pointer type template default": "\n".join(
            [
                "TemplateTypeParmDecl T",
                "TemplateArgument type 'RouteInputSample *'",
            ]
        ),
    }

    if validate_ast(valid_ast):
        print("AST validator self-test rejected its valid fixture", file=sys.stderr)
        return 1

    for name, fixture in adversarial_cases.items():
        if not validate_ast(f"{valid_ast}\n{fixture}"):
            print(
                f"AST validator self-test missed adversarial case: {name}",
                file=sys.stderr,
            )
            return 1

    valid_header = "#pragma once\nnamespace runplay { struct Value { int field; }; }\n"
    invalid_headers = {
        "global declaration": "namespace runplay {}\nusing Hidden = int*;\n",
        "alternate namespace": (
            "namespace runplay {}\n"
            "namespace escape { using Hidden = runplay::Value*; }\n"
        ),
        "public template declaration": (
            "namespace runplay { "
            "template<typename T> using Hidden = std::add_pointer_t<T>; "
            "}\n"
        ),
    }
    if namespace_errors_for_text(valid_header):
        print("namespace validator rejected its valid fixture", file=sys.stderr)
        return 1
    for name, fixture in invalid_headers.items():
        if not namespace_errors_for_text(fixture):
            print(
                f"namespace validator missed adversarial case: {name}",
                file=sys.stderr,
            )
            return 1

    return 0


def namespace_errors_for_text(source: str) -> list[str]:
    tokens = cpp_code_tokens(source)
    errors: list[str] = []
    if "template" in tokens:
        return ["public template declarations are unsupported"]
    depth = 0
    index = 0

    while index < len(tokens):
        token = tokens[index]
        if depth > 0:
            if token == "{":
                depth += 1
            elif token == "}":
                depth -= 1
            index += 1
            continue
        if token == ";":
            index += 1
            continue
        if token != "namespace":
            errors.append(f"declaration outside runplay begins with {token!r}")
            break
        index += 1
        if index >= len(tokens) or tokens[index] != "runplay":
            errors.append("unsupported top-level namespace")
            break
        index += 1
        while (
            index + 1 < len(tokens)
            and tokens[index] == "::"
            and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", tokens[index + 1])
        ):
            index += 2
        if index >= len(tokens) or tokens[index] != "{":
            errors.append("namespace runplay is not braced")
            break
        depth = 1
        index += 1

    if depth != 0 and not errors:
        errors.append("unbalanced braces")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="run adversarial parser fixtures instead of reading Clang AST input",
    )
    parser.add_argument(
        "--headers",
        nargs="*",
        default=[],
        help="public headers whose source declarations must stay under runplay",
    )
    args = parser.parse_args()

    if args.self_test:
        return run_self_test()

    errors = validate_ast(sys.stdin.read())
    for header in args.headers:
        errors.extend(validate_namespace_envelope(Path(header)))
    for error in errors:
        print(error, file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
