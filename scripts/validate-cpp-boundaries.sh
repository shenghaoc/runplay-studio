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

# Direct Swift imports of RunPlayEngineCpp outside the Interop adapter (and
# outside the engine's own non-Swift tree) are forbidden.
SWIFT_IMPORTS=()
while IFS= read -r line; do
  SWIFT_IMPORTS+=("$line")
done < <(grep -RIn --include='*.swift' -E '^[[:space:]]*(internal[[:space:]]+|private[[:space:]]+|public[[:space:]]+|@_implementationOnly[[:space:]]+)?import[[:space:]]+RunPlayEngineCpp\b' . 2>/dev/null || true)

allowed_import_regex='^\./RunPlayCore/Sources/Interop/'

for entry in "${SWIFT_IMPORTS[@]+"${SWIFT_IMPORTS[@]}"}"; do
  [[ -z "${entry:-}" ]] && continue
  file="${entry%%:*}"
  # Normalize to ./relative
  case "$file" in
    ./*) rel="$file" ;;
    /*) rel=".${file#"$ROOT"}" ;;
    *) rel="./$file" ;;
  esac
  if [[ "$rel" =~ $allowed_import_regex ]]; then
    pass "allowed engine import: $rel"
  else
    fail "unexpected import of RunPlayEngineCpp in $rel (only RunPlayCore/Sources/Interop/ may import it)"
  fi
done

if [[ ${#SWIFT_IMPORTS[@]} -eq 0 ]]; then
  fail "no Swift file imports RunPlayEngineCpp (expected Interop adapter)"
fi

# Inspect SwiftPM's parsed dependency graph rather than line-oriented manifest
# text, where target names and dependency entries naturally occur on different
# lines.
if swift package dump-package | python3 scripts/validate-cpp-package-graph.py; then
  pass "SwiftPM target dependency graph preserves Core → EngineCpp"
else
  fail "SwiftPM target dependency graph violates the EngineCpp boundary"
fi

# Grep Platform and Studio sources for any engine import (belt and suspenders).
import_engine_re='^[[:space:]]*(internal[[:space:]]+|private[[:space:]]+|public[[:space:]]+|@_implementationOnly[[:space:]]+)?import[[:space:]]+RunPlayEngineCpp\b'
for layer in RunPlayPlatform/Sources RunPlayStudio/Sources; do
  if [[ -d "$layer" ]]; then
    if grep -RIn --include='*.swift' -E "$import_engine_re" "$layer" >/dev/null 2>&1; then
      fail "$layer imports RunPlayEngineCpp (must go through RunPlayCore only)"
    else
      pass "$layer does not import RunPlayEngineCpp"
    fi
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
