#!/usr/bin/env python3
"""Validate the Clang AST for RunPlayEngineCpp's public runplay namespace."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
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
CPP_TOKEN_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*|::|[{};]")
VECTOR_TYPE_RE = re.compile(
    r"(^|[^A-Za-z0-9_:])"
    r"(?:(?:[A-Za-z_][A-Za-z0-9_]*)::)*vector\s*<"
)
# Positional and sum types must not cross the Swift boundary. A value-returning
# engine function has to name its fields, the way `LocalMeters` does, so Swift
# reads documented members instead of tuple element positions.
POSITIONAL_TYPE_RE = re.compile(
    r"(^|[^A-Za-z0-9_:])"
    r"(?:(?:[A-Za-z_][A-Za-z0-9_]*)::)*(?:pair|tuple|variant)\s*<"
)


@dataclass(frozen=True)
class ApprovedPointerParameter:
    name: str
    type_text: str
    mutable_output: bool = False


@dataclass(frozen=True)
class ApprovedPointerFunction:
    name: str
    type_text: str
    parameters: tuple[ApprovedPointerParameter, ...]


# Declarative allow-list of public pointer-bearing free functions. Only these
# exact names, return types, parameter names, pointer constness, and noexcept
# contracts may appear in the public AST.
APPROVED_POINTER_FUNCTIONS: tuple[ApprovedPointerFunction, ...] = (
    ApprovedPointerFunction(
        name="inspect_route_batch",
        type_text=(
            "RouteBatchInspection "
            "(const RouteInputSample *, std::size_t) noexcept"
        ),
        parameters=(
            ApprovedPointerParameter(
                name="samples",
                type_text="const RouteInputSample *",
            ),
        ),
    ),
    ApprovedPointerFunction(
        name="compute_route_step_distances",
        type_text=(
            "RouteStepDistanceSummary "
            "(const RouteInputSample *, std::size_t, double *, std::size_t) "
            "noexcept"
        ),
        parameters=(
            ApprovedPointerParameter(
                name="samples",
                type_text="const RouteInputSample *",
            ),
            ApprovedPointerParameter(
                name="step_distances_meters",
                type_text="double *",
                mutable_output=True,
            ),
        ),
    ),
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


def match_approved_function(
    line: str,
    types: list[str],
) -> ApprovedPointerFunction | None:
    if not types:
        return None
    for approved in APPROVED_POINTER_FUNCTIONS:
        if (
            re.search(rf"\b{re.escape(approved.name)}\b", line) is not None
            and types[0] == approved.type_text
        ):
            return approved
    return None


def match_approved_parameter(
    line: str,
    types: list[str],
) -> ApprovedPointerParameter | None:
    if not types:
        return None
    for approved in APPROVED_POINTER_FUNCTIONS:
        for parameter in approved.parameters:
            if (
                re.search(rf"\b{re.escape(parameter.name)}\b", line) is not None
                and types[0] == parameter.type_text
            ):
                return parameter
    return None


def validate_ast(ast_text: str) -> list[str]:
    errors: list[str] = []
    function_counts = {function.name: 0 for function in APPROVED_POINTER_FUNCTIONS}
    parameter_counts: dict[tuple[str, str], int] = {
        (function.name, parameter.name): 0
        for function in APPROVED_POINTER_FUNCTIONS
        for parameter in function.parameters
    }
    mutable_output_count = 0
    # Track the nearest enclosing approved function so parameters are counted
    # against the correct declaration when multiple pointer APIs exist.
    current_function: str | None = None

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

        if any(POSITIONAL_TYPE_RE.search(value) for value in types):
            errors.append(
                f"public declaration exposes std::pair, std::tuple, or "
                f"std::variant: {line}"
            )

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

        if kind == "FunctionDecl":
            approved_function = match_approved_function(line, types)
            if approved_function is None:
                errors.append(
                    f"unsupported public raw pointer declaration: {line}"
                )
                current_function = None
                continue
            function_counts[approved_function.name] += 1
            current_function = approved_function.name
            continue

        if kind == "ParmVarDecl":
            approved_parameter = match_approved_parameter(line, types)
            if approved_parameter is None or current_function is None:
                errors.append(
                    f"unsupported public raw pointer declaration: {line}"
                )
                continue
            # Confirm the parameter belongs to the approved function currently
            # being parsed by requiring the parameter name+type on that API.
            owned = any(
                parameter.name == approved_parameter.name
                and parameter.type_text == approved_parameter.type_text
                for function in APPROVED_POINTER_FUNCTIONS
                if function.name == current_function
                for parameter in function.parameters
            )
            if not owned:
                errors.append(
                    f"unsupported public raw pointer declaration: {line}"
                )
                continue
            key = (current_function, approved_parameter.name)
            parameter_counts[key] = parameter_counts.get(key, 0) + 1
            if approved_parameter.mutable_output:
                mutable_output_count += 1
            continue

        errors.append(f"unsupported public raw pointer declaration: {line}")

    for function in APPROVED_POINTER_FUNCTIONS:
        count = function_counts[function.name]
        if count != 1:
            errors.append(
                f"expected exactly one pointer-bearing {function.name} "
                f"declaration, found {count}"
            )
        for parameter in function.parameters:
            key = (function.name, parameter.name)
            count = parameter_counts.get(key, 0)
            if count != 1:
                errors.append(
                    f"expected exactly one {parameter.type_text} "
                    f"{parameter.name} parameter on {function.name}, "
                    f"found {count}"
                )

    approved_mutable_outputs = sum(
        1
        for function in APPROVED_POINTER_FUNCTIONS
        for parameter in function.parameters
        if parameter.mutable_output
    )
    if mutable_output_count != approved_mutable_outputs:
        errors.append(
            "expected exactly one approved mutable output pointer, "
            f"found {mutable_output_count}"
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
                "'RouteBatchInspection "
                "(const RouteInputSample *, std::size_t) noexcept'"
            ),
            "ParmVarDecl samples 'const RouteInputSample *'",
            (
                "FunctionDecl compute_route_step_distances "
                "'RouteStepDistanceSummary "
                "(const RouteInputSample *, std::size_t, double *, std::size_t) "
                "noexcept'"
            ),
            "ParmVarDecl samples 'const RouteInputSample *'",
            "ParmVarDecl step_distances_meters 'double *'",
            "VarDecl earth_radius_meters 'const double'",
            "CXXRecordDecl struct LocalMeters definition",
            "FieldDecl x_meters 'double'",
            "FieldDecl z_meters 'double'",
            "FunctionDecl is_valid_coordinate 'bool (double, double) noexcept'",
            (
                "FunctionDecl haversine_distance_meters "
                "'double (double, double, double, double) noexcept'"
            ),
            (
                "FunctionDecl project_lat_lon_to_local_meters "
                "'LocalMeters (double, double, double, double) noexcept'"
            ),
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
        "throwing geodesy function": (
            "FunctionDecl haversine_distance_meters "
            "'double (double, double, double, double)'"
        ),
        "geodesy pointer out-parameter": "\n".join(
            [
                (
                    "FunctionDecl project_lat_lon_to_local_meters "
                    "'void (double, double, LocalMeters *) noexcept'"
                ),
                "ParmVarDecl out_value 'LocalMeters *'",
            ]
        ),
        "geodesy std::pair return": (
            "FunctionDecl project_lat_lon_to_local_meters "
            "'std::pair<double, double> (double, double) noexcept'"
        ),
        "geodesy std::tuple return": (
            "FunctionDecl project_lat_lon_to_local_meters "
            "'std::tuple<double, double> (double, double) noexcept'"
        ),
        "geodesy std::variant return": (
            "FunctionDecl haversine_distance_meters "
            "'std::variant<double, int> (double, double) noexcept'"
        ),
        "geodesy std::vector return": (
            "FunctionDecl project_route "
            "'std::vector<LocalMeters> (double, double) noexcept'"
        ),
        "writable input pointer": "\n".join(
            [
                (
                    "FunctionDecl compute_route_step_distances "
                    "'RouteStepDistanceSummary "
                    "(RouteInputSample *, std::size_t, double *, std::size_t) "
                    "noexcept'"
                ),
                "ParmVarDecl samples 'RouteInputSample *'",
                "ParmVarDecl step_distances_meters 'double *'",
            ]
        ),
        "const output pointer": "\n".join(
            [
                (
                    "FunctionDecl compute_route_step_distances "
                    "'RouteStepDistanceSummary "
                    "(const RouteInputSample *, std::size_t, const double *, "
                    "std::size_t) noexcept'"
                ),
                "ParmVarDecl samples 'const RouteInputSample *'",
                "ParmVarDecl step_distances_meters 'const double *'",
            ]
        ),
        "output pointer with wrong element type": "\n".join(
            [
                (
                    "FunctionDecl compute_route_step_distances "
                    "'RouteStepDistanceSummary "
                    "(const RouteInputSample *, std::size_t, float *, "
                    "std::size_t) noexcept'"
                ),
                "ParmVarDecl samples 'const RouteInputSample *'",
                "ParmVarDecl step_distances_meters 'float *'",
            ]
        ),
        "missing output capacity": "\n".join(
            [
                (
                    "FunctionDecl compute_route_step_distances "
                    "'RouteStepDistanceSummary "
                    "(const RouteInputSample *, std::size_t, double *) noexcept'"
                ),
                "ParmVarDecl samples 'const RouteInputSample *'",
                "ParmVarDecl step_distances_meters 'double *'",
            ]
        ),
        "extra pointer parameter": "\n".join(
            [
                (
                    "FunctionDecl compute_route_step_distances "
                    "'RouteStepDistanceSummary "
                    "(const RouteInputSample *, std::size_t, double *, "
                    "std::size_t, int *) noexcept'"
                ),
                "ParmVarDecl samples 'const RouteInputSample *'",
                "ParmVarDecl step_distances_meters 'double *'",
                "ParmVarDecl scratch 'int *'",
            ]
        ),
        "renamed unapproved pointer function": "\n".join(
            [
                (
                    "FunctionDecl compute_route_steps "
                    "'RouteStepDistanceSummary "
                    "(const RouteInputSample *, std::size_t, double *, "
                    "std::size_t) noexcept'"
                ),
                "ParmVarDecl samples 'const RouteInputSample *'",
                "ParmVarDecl step_distances_meters 'double *'",
            ]
        ),
        "throwing step-distance function": (
            "FunctionDecl compute_route_step_distances "
            "'RouteStepDistanceSummary "
            "(const RouteInputSample *, std::size_t, double *, std::size_t)'"
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
        "public geodesy function template": (
            "namespace runplay { "
            "template<typename T> T haversine_distance_meters(T, T, T, T) noexcept; "
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
