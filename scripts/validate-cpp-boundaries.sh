#!/usr/bin/env bash
# validate-cpp-boundaries.sh — architectural boundary checks for RunPlayEngineCpp
#
# Verifies dependency and API-boundary rules for the C++ engine foundation.
# Exit 0 on success; non-zero with a concrete finding on failure.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

failures=0

fail() {
  echo "BOUNDARY FAIL: $*" >&2
  failures=$((failures + 1))
}

pass() {
  echo "OK: $*"
}

# --- Helpers -----------------------------------------------------------------

# Match code constructs, not comments: strip // line comments and /* */ blocks
# for the purpose of pattern checks on a single file.
strip_comments() {
  # Remove block comments then line comments. Not a full C++ preprocessor, but
  # sufficient to avoid flagging words that only appear in comments.
  perl -0777 -pe 's{/\*.*?\*/}{}gs; s{//[^\n]*}{}g' "$1"
}

# --- Structural presence -----------------------------------------------------

if [[ ! -d RunPlayEngineCpp/include ]]; then
  fail "missing RunPlayEngineCpp/include"
else
  pass "RunPlayEngineCpp/include present"
fi

if [[ ! -f RunPlayEngineCpp/include/RunPlayEngineCpp/RunPlayEngine.hpp ]]; then
  fail "missing public header RunPlayEngine.hpp"
else
  pass "public smoke header present"
fi

ROUTE_HEADER="RunPlayEngineCpp/include/RunPlayEngineCpp/RouteInterop.hpp"
if [[ ! -f "$ROUTE_HEADER" ]]; then
  fail "missing public route header RouteInterop.hpp"
else
  pass "public route interop header present"
fi

if strip_comments RunPlayEngineCpp/include/RunPlayEngineCpp/RunPlayEngine.hpp \
  | grep -Eq '#[[:space:]]*include[[:space:]]*"RunPlayEngineCpp/RouteInterop\.hpp"'; then
  pass "umbrella header includes RouteInterop.hpp"
else
  fail "RunPlayEngine.hpp must include RouteInterop.hpp"
fi

# --- Public C++ headers: prohibited constructs --------------------------------

PUBLIC_HEADERS=()
while IFS= read -r -d '' f; do
  PUBLIC_HEADERS+=("$f")
done < <(find RunPlayEngineCpp/include -type f \( -name '*.h' -o -name '*.hh' -o -name '*.hpp' -o -name '*.hxx' \) -print0 2>/dev/null)

if [[ ${#PUBLIC_HEADERS[@]} -eq 0 ]]; then
  fail "no public C++ headers found under RunPlayEngineCpp/include"
fi

for header in "${PUBLIC_HEADERS[@]}"; do
  body="$(strip_comments "$header")"

  # std::tuple / std::variant as type uses (not words in strings alone).
  if printf '%s' "$body" | grep -Eq '(^|[^[:alnum:]_])std::tuple([^[:alnum:]_]|$)'; then
    fail "$header exposes std::tuple in public API"
  fi
  if printf '%s' "$body" | grep -Eq '(^|[^[:alnum:]_])std::variant([^[:alnum:]_]|$)'; then
    fail "$header exposes std::variant in public API"
  fi
  if printf '%s' "$body" | grep -Eq '(^|[^[:alnum:]_])std::vector[[:space:]]*<'; then
    fail "$header exposes std::vector in public API"
  fi

  # throw expressions / throw specifications (not the word in a string literal heuristic).
  if printf '%s' "$body" | grep -Eq '(^|[^[:alnum:]_])throw[[:space:]]'; then
    fail "$header contains throw (exceptions must not cross the Swift boundary)"
  fi

  # Objective-C / Apple framework / Swift-generated headers.
  if printf '%s' "$body" | grep -Eq '#[[:space:]]*import[[:space:]]+<'; then
    fail "$header uses #import (Objective-C style) of a system header"
  fi
  if printf '%s' "$body" | grep -Eqi '#[[:space:]]*include[[:space:]]*[<"](Foundation|AppKit|UIKit|CoreFoundation|CoreLocation|Swift|swift)/'; then
    fail "$header includes Apple or Swift framework headers"
  fi
  if printf '%s' "$body" | grep -Eqi '#[[:space:]]*include[[:space:]]*[<"][^>"]*-Swift\.h[>"]'; then
    fail "$header includes a Swift-generated -Swift.h header"
  fi
done

if [[ $failures -eq 0 ]]; then
  pass "public C++ headers free of prohibited boundary types"
fi

# --- Route bulk-call shape and public AST contract ----------------------------

if [[ -f "$ROUTE_HEADER" ]]; then
  route_body="$(strip_comments "$ROUTE_HEADER" | tr '\n' ' ' | tr -s '[:space:]' ' ')"
  route_signature_re='RouteBatchInspection[[:space:]]+inspect_route_batch[[:space:]]*\([[:space:]]*const[[:space:]]+RouteInputSample[[:space:]]*\*[[:space:]]*samples[[:space:]]*,[[:space:]]*std::size_t[[:space:]]+sample_count[[:space:]]*\)[[:space:]]*noexcept[[:space:]]*;'
  if [[ "$route_body" =~ $route_signature_re ]]; then
    pass "route boundary is one const pointer-plus-count noexcept call"
  else
    fail "inspect_route_batch must use const RouteInputSample* plus size_t and noexcept"
  fi
fi

if python3 scripts/validate-cpp-public-ast.py --self-test; then
  pass "public C++ AST validator adversarial fixtures"
else
  fail "public C++ AST validator self-test failed"
fi

if ! command -v clang++ >/dev/null 2>&1; then
  fail "clang++ is required for syntax-aware public C++ boundary validation"
else
  AST_INCLUDE_ARGS=()
  for header in "${PUBLIC_HEADERS[@]}"; do
    AST_INCLUDE_ARGS+=(-include "${header#RunPlayEngineCpp/include/}")
  done

  if public_dependencies="$(
    clang++ \
      -std=c++2b \
      -I RunPlayEngineCpp/include \
      "${AST_INCLUDE_ARGS[@]}" \
      -MM \
      -MT dependencies \
      -x c++ \
      /dev/null
  )"; then
    public_dependencies="${public_dependencies//\\/ }"
    unexpected_public_dependency=0
    for dependency in $public_dependencies; do
      case "$dependency" in
        dependencies:|/dev/null|*/SDKs/*.sdk/SDKSettings.json)
          continue
          ;;
      esac

      if [[ "$dependency" == "$ROOT/"* ]]; then
        dependency="${dependency#"$ROOT/"}"
      elif [[ "$dependency" == /* ]]; then
        fail "public C++ headers include external non-system file: $dependency"
        unexpected_public_dependency=1
        continue
      else
        dependency="${dependency#./}"
      fi

      dependency_is_public=0
      for public_header in "${PUBLIC_HEADERS[@]}"; do
        if [[ "$dependency" == "$public_header" ]]; then
          dependency_is_public=1
          break
        fi
      done
      if [[ $dependency_is_public -eq 0 ]]; then
        fail "public C++ headers include non-public project file: $dependency"
        unexpected_public_dependency=1
      fi
    done
    if [[ $unexpected_public_dependency -eq 0 ]]; then
      pass "public C++ headers depend only on validated public project headers"
    fi
  else
    fail "clang++ could not enumerate public C++ header dependencies"
  fi

  if public_ast="$(
    clang++ \
      -std=c++2b \
      -I RunPlayEngineCpp/include \
      "${AST_INCLUDE_ARGS[@]}" \
      -Xclang -ast-dump \
      -Xclang -ast-dump-filter \
      -Xclang runplay \
      -fsyntax-only \
      -x c++ \
      /dev/null
  )"; then
    if printf '%s\n' "$public_ast" \
      | python3 scripts/validate-cpp-public-ast.py \
          --headers "${PUBLIC_HEADERS[@]}"; then
      pass "public C++ AST permits only the noexcept route buffer pointer"
    else
      fail "public C++ AST violates pointer, vector, or noexcept rules"
    fi
  else
    fail "clang++ could not parse the public C++ headers for boundary validation"
  fi
fi

# --- Engine sources: no Apple frameworks -------------------------------------

ENGINE_SOURCES=()
while IFS= read -r -d '' f; do
  ENGINE_SOURCES+=("$f")
done < <(find RunPlayEngineCpp -type f \( -name '*.c' -o -name '*.cc' -o -name '*.cpp' -o -name '*.cxx' -o -name '*.h' -o -name '*.hh' -o -name '*.hpp' -o -name '*.hxx' -o -name '*.m' -o -name '*.mm' \) -print0 2>/dev/null)

for src in "${ENGINE_SOURCES[@]}"; do
  body="$(strip_comments "$src")"
  if printf '%s' "$body" | grep -Eqi '#[[:space:]]*(include|import)[[:space:]]*[<"](Foundation|AppKit|UIKit|CoreFoundation|CoreLocation|MapKit|SceneKit|SwiftUI|Combine)/'; then
    fail "$src imports an Apple framework"
  fi
  if printf '%s' "$body" | grep -Eqi '#[[:space:]]*(include|import)[[:space:]]*[<"][^>"]*-Swift\.h[>"]'; then
    fail "$src includes a Swift-generated header"
  fi
  # No Objective-C++ in the engine.
  case "$src" in
    *.m|*.mm) fail "$src is Objective-C/Objective-C++ (forbidden in RunPlayEngineCpp)" ;;
  esac
done

if [[ $failures -eq 0 ]]; then
  pass "RunPlayEngineCpp sources avoid Apple frameworks and ObjC"
fi

# --- Lower layers must not depend upward -------------------------------------

# C++ engine must not reference upper Swift module names as imports or includes.
for src in "${ENGINE_SOURCES[@]}"; do
  body="$(strip_comments "$src")"
  if printf '%s' "$body" | grep -Eq '(^|[^[:alnum:]_])(RunPlayCore|RunPlayPlatform|RunPlayStudio)([^[:alnum:]_]|$)'; then
    # Allow the path segment "RunPlayEngineCpp" only; upper modules are forbidden.
    if printf '%s' "$body" | grep -Eq '(RunPlayCore|RunPlayPlatform|RunPlayStudio)'; then
      fail "$src references upper-layer module name (RunPlayCore/Platform/Studio)"
    fi
  fi
done

# --- Only the intended Swift adapter imports RunPlayEngineCpp -----------------

# Reconcile Swift frontend parse trees with complete token streams. The parser
# rejects expression/string/regex decoys; the lexer also inspects inactive
# conditional-compilation branches for attributed, scoped, or multiline imports.
SWIFT_FILES=()
while IFS= read -r swift_file; do
  SWIFT_FILES+=("$swift_file")
done < <(
  find . \
    \( \
      -path './.git' \
      -o -path './.build' \
      -o -path './.swiftpm' \
      -o -path './local-workouts' \
      -o -path './private-workouts' \
    \) -prune \
    -o -type f -name '*.swift' -print 2>/dev/null \
    | LC_ALL=C sort
)

if python3 scripts/validate-swift-engine-imports.py --self-test; then
  pass "Swift engine import lexer adversarial fixtures"
else
  fail "Swift engine import lexer self-test failed"
fi

swift_import_validation_ok=0
if swift_import_output="$(
  python3 scripts/validate-swift-engine-imports.py \
    --allowed-prefix RunPlayCore/Sources/Interop \
    "${SWIFT_FILES[@]}"
)"; then
  swift_import_validation_ok=1
  while IFS= read -r allowed_import; do
    [[ -n "$allowed_import" ]] \
      && pass "allowed internal engine import: ./$allowed_import"
  done <<< "$swift_import_output"
else
  fail "Swift engine imports violate path, access, attribute, or scope rules"
fi

# Internal imports are compiler-enforced against use in public declarations.
# Also reject same-line public declarations that name the imported route types
# so source review receives a direct, concrete diagnostic.
public_route_type_re='^[[:space:]]*(public|open|package)[^/]*(runplay\.(RouteInputSample|RouteBatchInspection|RouteInteropStatus)|RouteOptional(Double|SourceIndex))'
public_route_type_leaks=()
for swift_file in "${SWIFT_FILES[@]}"; do
  while IFS= read -r leak; do
    [[ -n "$leak" ]] && public_route_type_leaks+=("$swift_file:$leak")
  done < <(
    perl -0777 -pe 's{/\*.*?\*/}{}gs; s{//[^\n]*}{}g' "$swift_file" \
      | grep -En "$public_route_type_re" || true
  )
done

if [[ ${#public_route_type_leaks[@]} -eq 0 ]]; then
  pass "public Swift declarations remain free of C++ route types"
else
  for leak in "${public_route_type_leaks[@]}"; do
    fail "public Swift declaration exposes C++ route type: $leak"
  done
fi

# --- Parity-only geodesy adapter stays out of production paths ---------------

# The C++ geodesy primitives are validated but not cut over. Every production
# GeoDistance caller runs inside a per-point loop, so routing production through
# the scalar adapter would create the per-element cross-language calls this
# repository forbids. Enforce that mechanically instead of by comment.
GEODESY_BRIDGE_SOURCE="RunPlayCore/Sources/Interop/RunPlayGeodesyBridge.swift"
GEO_DISTANCE_SOURCE="RunPlayCore/Sources/Services/GeoDistance.swift"

if [[ ! -f "$GEODESY_BRIDGE_SOURCE" ]]; then
  fail "missing parity-only geodesy adapter $GEODESY_BRIDGE_SOURCE"
fi
if [[ ! -f "$GEO_DISTANCE_SOURCE" ]]; then
  fail "missing production Swift geodesy reference $GEO_DISTANCE_SOURCE"
fi

geodesy_bridge_symbol_re='(^|[^[:alnum:]_])(RunPlayGeodesyBridge|RunPlayLocalMeters)([^[:alnum:]_]|$)'
geodesy_bridge_leaks=()
for swift_file in "${SWIFT_FILES[@]}"; do
  relative_swift_file="${swift_file#./}"
  case "$relative_swift_file" in
    "$GEODESY_BRIDGE_SOURCE") continue ;;
    RunPlayCore/Tests/*|RunPlayPlatform/Tests/*|RunPlayStudio/Tests/*) continue ;;
  esac
  while IFS= read -r leak; do
    [[ -n "$leak" ]] && geodesy_bridge_leaks+=("$relative_swift_file:$leak")
  done < <(strip_comments "$swift_file" | grep -En "$geodesy_bridge_symbol_re" || true)
done

if [[ ${#geodesy_bridge_leaks[@]} -eq 0 ]]; then
  pass "parity-only geodesy adapter is used only by its own file and tests"
else
  for leak in "${geodesy_bridge_leaks[@]}"; do
    fail "production Swift code uses the parity-only geodesy adapter: $leak"
  done
fi

if [[ -f "$GEO_DISTANCE_SOURCE" ]]; then
  if strip_comments "$GEO_DISTANCE_SOURCE" \
    | grep -Eq "$geodesy_bridge_symbol_re"; then
    fail "$GEO_DISTANCE_SOURCE must remain the Swift parity oracle, not a C++ caller"
  else
    pass "GeoDistance.swift remains an independent Swift implementation"
  fi
fi

# Inspect SwiftPM's parsed dependency graph rather than line-oriented manifest
# text, where target names and dependency entries naturally occur on different
# lines.
if swift package dump-package | python3 scripts/validate-cpp-package-graph.py; then
  pass "SwiftPM target dependency graph preserves Core → EngineCpp"
else
  fail "SwiftPM target dependency graph violates the EngineCpp boundary"
fi

# The token-aware scan above includes both upper layers.
for layer in RunPlayPlatform/Sources RunPlayStudio/Sources; do
  if [[ -d "$layer" && $swift_import_validation_ok -eq 1 ]]; then
    pass "$layer does not import RunPlayEngineCpp"
  fi
done

# --- Summary -----------------------------------------------------------------

if [[ $failures -ne 0 ]]; then
  echo "" >&2
  echo "validate-cpp-boundaries: $failures failure(s)" >&2
  exit 1
fi

echo ""
echo "validate-cpp-boundaries: all checks passed"
exit 0
