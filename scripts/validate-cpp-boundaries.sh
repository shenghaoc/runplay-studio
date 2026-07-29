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

GEOMETRY_HEADER="RunPlayEngineCpp/include/RunPlayEngineCpp/RouteGeometry.hpp"
if [[ ! -f "$GEOMETRY_HEADER" ]]; then
  fail "missing public route geometry header RouteGeometry.hpp"
else
  pass "public route geometry header present"
fi

QUALITY_HEADER="RunPlayEngineCpp/include/RunPlayEngineCpp/RouteQualityPipeline.hpp"
if [[ ! -f "$QUALITY_HEADER" ]]; then
  fail "missing public route quality header RouteQualityPipeline.hpp"
else
  pass "public route quality pipeline header present"
fi

if strip_comments RunPlayEngineCpp/include/RunPlayEngineCpp/RunPlayEngine.hpp \
  | grep -Eq '#[[:space:]]*include[[:space:]]*"RunPlayEngineCpp/RouteInterop\.hpp"'; then
  pass "umbrella header includes RouteInterop.hpp"
else
  fail "RunPlayEngine.hpp must include RouteInterop.hpp"
fi

if strip_comments RunPlayEngineCpp/include/RunPlayEngineCpp/RunPlayEngine.hpp \
  | grep -Eq '#[[:space:]]*include[[:space:]]*"RunPlayEngineCpp/RouteGeometry\.hpp"'; then
  pass "umbrella header includes RouteGeometry.hpp"
else
  fail "RunPlayEngine.hpp must include RouteGeometry.hpp"
fi

if strip_comments RunPlayEngineCpp/include/RunPlayEngineCpp/RunPlayEngine.hpp \
  | grep -Eq '#[[:space:]]*include[[:space:]]*"RunPlayEngineCpp/RouteQualityPipeline\.hpp"'; then
  pass "umbrella header includes RouteQualityPipeline.hpp"
else
  fail "RunPlayEngine.hpp must include RouteQualityPipeline.hpp"
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

if [[ -f "$GEOMETRY_HEADER" ]]; then
  geometry_body="$(strip_comments "$GEOMETRY_HEADER" | tr '\n' ' ' | tr -s '[:space:]' ' ')"
  geometry_signature_re='RouteStepDistanceSummary[[:space:]]+compute_route_step_distances[[:space:]]*\([[:space:]]*const[[:space:]]+RouteInputSample[[:space:]]*\*[[:space:]]*samples[[:space:]]*,[[:space:]]*std::size_t[[:space:]]+sample_count[[:space:]]*,[[:space:]]*double[[:space:]]*\*[[:space:]]*step_distances_meters[[:space:]]*,[[:space:]]*std::size_t[[:space:]]+step_distance_capacity[[:space:]]*\)[[:space:]]*noexcept[[:space:]]*;'
  if [[ "$geometry_body" =~ $geometry_signature_re ]]; then
    pass "step-distance boundary is one bulk input/output noexcept call"
  else
    fail "compute_route_step_distances must use const input*, size_t, double* output, capacity, and noexcept"
  fi
fi

if [[ -f "$QUALITY_HEADER" ]]; then
  quality_body="$(strip_comments "$QUALITY_HEADER" | tr '\n' ' ' | tr -s '[:space:]' ' ')"
  quality_signature_re='RouteQualityPipelineSummary[[:space:]]+process_route_quality_geometry[[:space:]]*\([[:space:]]*const[[:space:]]+RouteInputSample[[:space:]]*\*[[:space:]]*samples[[:space:]]*,[[:space:]]*std::size_t[[:space:]]+sample_count[[:space:]]*,[[:space:]]*RouteQualityGeometryPolicy[[:space:]]+policy[[:space:]]*,[[:space:]]*RouteQualityDistancePolicy[[:space:]]+distance_policy[[:space:]]*,[[:space:]]*const[[:space:]]+std::uint8_t[[:space:]]*\*[[:space:]]*supplied_selection_by_sample[[:space:]]*,[[:space:]]*std::size_t[[:space:]]+supplied_selection_count[[:space:]]*,[[:space:]]*RouteQualityOutputSample[[:space:]]*\*[[:space:]]*output_samples[[:space:]]*,[[:space:]]*std::size_t[[:space:]]+output_capacity[[:space:]]*\)[[:space:]]*noexcept[[:space:]]*;'
  if [[ "$quality_body" =~ $quality_signature_re ]]; then
    pass "route-quality geometry boundary is one bulk input/selection/output noexcept call"
  else
    fail "process_route_quality_geometry must use const input*, selection*, output*, counts/capacities, and noexcept"
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
      pass "public C++ AST permits only the documented noexcept route buffer pointers"
    else
      fail "public C++ AST violates pointer, boundary-type, or noexcept rules"
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

# --- Scalar geodesy stays parity-only; combined quality is production --------

# Scalar C++ geodesy symbols remain parity-only. Production route-quality
# geometry stages 2–4 must go through the combined bridge, never one call per
# point. The step-distance bridge remains transitional/test-focused.
GEODESY_BRIDGE_SOURCE="RunPlayCore/Sources/Interop/RunPlayGeodesyBridge.swift"
GEO_DISTANCE_SOURCE="RunPlayCore/Sources/Services/GeoDistance.swift"
STEP_DISTANCE_BRIDGE_SOURCE="RunPlayCore/Sources/Interop/RunPlayRouteStepDistanceBridge.swift"
ROUTE_QUALITY_BRIDGE_SOURCE="RunPlayCore/Sources/Interop/RunPlayRouteQualityBridge.swift"
ROUTE_QUALITY_PROCESSOR_SOURCE="RunPlayCore/Sources/Services/RouteQualityProcessor.swift"
ROUTE_INPUT_BUFFER_SOURCE="RunPlayCore/Sources/Interop/RunPlayRouteInputBuffer.swift"

if [[ ! -f "$GEODESY_BRIDGE_SOURCE" ]]; then
  fail "missing parity-only geodesy adapter $GEODESY_BRIDGE_SOURCE"
fi
if [[ ! -f "$GEO_DISTANCE_SOURCE" ]]; then
  fail "missing production Swift geodesy reference $GEO_DISTANCE_SOURCE"
fi
if [[ ! -f "$STEP_DISTANCE_BRIDGE_SOURCE" ]]; then
  fail "missing transitional step-distance bridge $STEP_DISTANCE_BRIDGE_SOURCE"
fi
if [[ ! -f "$ROUTE_QUALITY_BRIDGE_SOURCE" ]]; then
  fail "missing production route-quality bridge $ROUTE_QUALITY_BRIDGE_SOURCE"
fi
if [[ ! -f "$ROUTE_INPUT_BUFFER_SOURCE" ]]; then
  fail "missing shared native route-input builder $ROUTE_INPUT_BUFFER_SOURCE"
fi
if [[ ! -f "$ROUTE_QUALITY_PROCESSOR_SOURCE" ]]; then
  fail "missing production RouteQualityProcessor $ROUTE_QUALITY_PROCESSOR_SOURCE"
fi

geodesy_reference_re='(^|[^[:alnum:]_])((RunPlayGeodesyBridge|RunPlayLocalMeters)|runplay[[:space:]]*\.[[:space:]]*(earth_radius_meters|LocalMeters|is_valid_coordinate|haversine_distance_meters|project_lat_lon_to_local_meters))([^[:alnum:]_]|$)'

geodesy_reference_positive_fixtures=(
  'RunPlayGeodesyBridge.distanceMeters(latitude1: 0, longitude1: 0, latitude2: 0, longitude2: 0)'
  'let projected: runplay.LocalMeters = runplay.project_lat_lon_to_local_meters(0, 0, 0, 0)'
  'let radius = runplay . earth_radius_meters'
)
geodesy_reference_negative_fixtures=(
  'RunPlayGeoDistance.distanceMeters(0, 0)'
  'runplay.inspect_route_batch(buffer.baseAddress, buffer.count)'
  'runplay.compute_route_step_distances(input, count, output, capacity)'
  'let LocalMetersPerSecond = 1.0'
)
geodesy_reference_matcher_ok=1
for fixture in "${geodesy_reference_positive_fixtures[@]}"; do
  if ! printf '%s' "$fixture" | grep -Eq "$geodesy_reference_re"; then
    geodesy_reference_matcher_ok=0
  fi
done
for fixture in "${geodesy_reference_negative_fixtures[@]}"; do
  if printf '%s' "$fixture" | grep -Eq "$geodesy_reference_re"; then
    geodesy_reference_matcher_ok=0
  fi
done
if [[ $geodesy_reference_matcher_ok -eq 1 ]]; then
  pass "parity-only geodesy reference matcher adversarial fixtures"
else
  fail "parity-only geodesy reference matcher failed its adversarial fixtures"
fi

geodesy_reference_leaks=()
for swift_file in "${SWIFT_FILES[@]}"; do
  relative_swift_file="${swift_file#./}"
  case "$relative_swift_file" in
    "$GEODESY_BRIDGE_SOURCE") continue ;;
    RunPlayCore/Tests/*|RunPlayPlatform/Tests/*|RunPlayStudio/Tests/*) continue ;;
  esac
  while IFS= read -r leak; do
    [[ -n "$leak" ]] && geodesy_reference_leaks+=("$relative_swift_file:$leak")
  done < <(strip_comments "$swift_file" | grep -En "$geodesy_reference_re" || true)
done

if [[ ${#geodesy_reference_leaks[@]} -eq 0 ]]; then
  pass "parity-only scalar geodesy APIs are referenced only by their bridge and tests"
else
  for leak in "${geodesy_reference_leaks[@]}"; do
    fail "production Swift code uses a parity-only scalar geodesy API: $leak"
  done
fi

if [[ -f "$GEO_DISTANCE_SOURCE" ]]; then
  if strip_comments "$GEO_DISTANCE_SOURCE" \
    | grep -Eq "$geodesy_reference_re"; then
    fail "$GEO_DISTANCE_SOURCE must remain the Swift parity oracle, not a C++ caller"
  else
    pass "GeoDistance.swift remains an independent Swift implementation"
  fi
fi

# Only the step-distance bridge may invoke the transitional C++ bulk symbol.
# Comments and string literals are stripped first so documentation cannot
# create false positives, and tests remain free to mention the symbol by name.
step_distance_symbol_re='(^|[^[:alnum:]_])runplay[[:space:]]*\.[[:space:]]*compute_route_step_distances([^[:alnum:]_]|$)'
step_distance_symbol_positive=(
  'runplay.compute_route_step_distances(input.baseAddress, input.count, output.baseAddress, output.count)'
  'let summary = runplay . compute_route_step_distances(a, b, c, d)'
)
step_distance_symbol_negative=(
  'RunPlayRouteStepDistanceBridge.compute(points)'
  'let text = "compute_route_step_distances"'
  'func compute_route_step_distances_helper() {}'
)
step_distance_symbol_matcher_ok=1
for fixture in "${step_distance_symbol_positive[@]}"; do
  if ! printf '%s' "$fixture" | grep -Eq "$step_distance_symbol_re"; then
    step_distance_symbol_matcher_ok=0
  fi
done
for fixture in "${step_distance_symbol_negative[@]}"; do
  if printf '%s' "$fixture" | grep -Eq "$step_distance_symbol_re"; then
    step_distance_symbol_matcher_ok=0
  fi
done
if [[ $step_distance_symbol_matcher_ok -eq 1 ]]; then
  pass "bulk step-distance symbol matcher adversarial fixtures"
else
  fail "bulk step-distance symbol matcher failed its adversarial fixtures"
fi

step_distance_symbol_leaks=()
for swift_file in "${SWIFT_FILES[@]}"; do
  relative_swift_file="${swift_file#./}"
  case "$relative_swift_file" in
    "$STEP_DISTANCE_BRIDGE_SOURCE") continue ;;
    RunPlayCore/Tests/*|RunPlayPlatform/Tests/*|RunPlayStudio/Tests/*) continue ;;
  esac
  while IFS= read -r leak; do
    [[ -n "$leak" ]] && step_distance_symbol_leaks+=("$relative_swift_file:$leak")
  done < <(strip_comments "$swift_file" | grep -En "$step_distance_symbol_re" || true)
done

if [[ ${#step_distance_symbol_leaks[@]} -eq 0 ]]; then
  pass "compute_route_step_distances is invoked only from the transitional bridge"
else
  for leak in "${step_distance_symbol_leaks[@]}"; do
    fail "compute_route_step_distances used outside the transitional bridge: $leak"
  done
fi

# Only the route-quality bridge may invoke the combined geometry symbol.
quality_symbol_re='(^|[^[:alnum:]_])runplay[[:space:]]*\.[[:space:]]*process_route_quality_geometry([^[:alnum:]_]|$)'
quality_symbol_positive=(
  'runplay.process_route_quality_geometry(input.baseAddress, input.count, policy, distance, selection, count, output.baseAddress, output.count)'
  'let summary = runplay . process_route_quality_geometry(a, b, c, d, e, f, g, h)'
)
quality_symbol_negative=(
  'RunPlayRouteQualityBridge.process(points, policy: policy, distancePolicy: .computeFromCoordinates, cancellationCheckStride: 1, isCancelled: { false })'
  'let text = "process_route_quality_geometry"'
  'func process_route_quality_geometry_helper() {}'
)
quality_symbol_matcher_ok=1
for fixture in "${quality_symbol_positive[@]}"; do
  if ! printf '%s' "$fixture" | grep -Eq "$quality_symbol_re"; then
    quality_symbol_matcher_ok=0
  fi
done
for fixture in "${quality_symbol_negative[@]}"; do
  if printf '%s' "$fixture" | grep -Eq "$quality_symbol_re"; then
    quality_symbol_matcher_ok=0
  fi
done
if [[ $quality_symbol_matcher_ok -eq 1 ]]; then
  pass "combined route-quality symbol matcher adversarial fixtures"
else
  fail "combined route-quality symbol matcher failed its adversarial fixtures"
fi

quality_symbol_leaks=()
for swift_file in "${SWIFT_FILES[@]}"; do
  relative_swift_file="${swift_file#./}"
  case "$relative_swift_file" in
    "$ROUTE_QUALITY_BRIDGE_SOURCE") continue ;;
    RunPlayCore/Tests/*|RunPlayPlatform/Tests/*|RunPlayStudio/Tests/*) continue ;;
  esac
  while IFS= read -r leak; do
    [[ -n "$leak" ]] && quality_symbol_leaks+=("$relative_swift_file:$leak")
  done < <(strip_comments "$swift_file" | grep -En "$quality_symbol_re" || true)
done

if [[ ${#quality_symbol_leaks[@]} -eq 0 ]]; then
  pass "process_route_quality_geometry is invoked only from the production quality bridge"
else
  for leak in "${quality_symbol_leaks[@]}"; do
    fail "process_route_quality_geometry used outside the quality bridge: $leak"
  done
fi

# RouteQualityProcessor must call the pure Swift quality bridge, not C++ symbols
# and not the transitional step-distance bridge.
if strip_comments "$ROUTE_QUALITY_PROCESSOR_SOURCE" \
  | grep -Eq '(^|[^[:alnum:]_])runplay[[:space:]]*\.'; then
  fail "RouteQualityProcessor must not reference C++ runplay symbols directly"
else
  pass "RouteQualityProcessor stays free of direct C++ symbols"
fi

if strip_comments "$ROUTE_QUALITY_PROCESSOR_SOURCE" \
  | grep -Eq '(^|[^[:alnum:]_])RunPlayRouteQualityBridge([^[:alnum:]_]|$)'; then
  pass "RouteQualityProcessor consumes the pure Swift route-quality bridge"
else
  fail "RouteQualityProcessor must call RunPlayRouteQualityBridge"
fi

if strip_comments "$ROUTE_QUALITY_PROCESSOR_SOURCE" \
  | grep -Eq '(^|[^[:alnum:]_])RunPlayRouteStepDistanceBridge([^[:alnum:]_]|$)'; then
  fail "RouteQualityProcessor must not call transitional RunPlayRouteStepDistanceBridge"
else
  pass "RouteQualityProcessor no longer calls the transitional step-distance bridge"
fi

if strip_comments "$ROUTE_QUALITY_PROCESSOR_SOURCE" \
  | grep -Eq '(^|[^[:alnum:]_])(RunPlayGeodesyBridge|haversine_distance_meters|is_valid_coordinate|project_lat_lon_to_local_meters)([^[:alnum:]_]|$)' \
  || strip_comments "$ROUTE_QUALITY_PROCESSOR_SOURCE" \
    | grep -Eq '(^|[^[:alnum:]_])runplay[[:space:]]*\.[[:space:]]*'; then
  fail "RouteQualityProcessor must not call scalar C++ geodesy"
else
  pass "RouteQualityProcessor does not call scalar C++ geodesy"
fi

# Quality bridge must not invoke the public step-distance boundary.
if strip_comments "$ROUTE_QUALITY_BRIDGE_SOURCE" \
  | grep -Eq "$step_distance_symbol_re" \
  || strip_comments "$ROUTE_QUALITY_BRIDGE_SOURCE" \
    | grep -Eq '(^|[^[:alnum:]_])RunPlayRouteStepDistanceBridge([^[:alnum:]_]|$)'; then
  fail "route-quality bridge must not call the public step-distance boundary"
else
  pass "route-quality bridge uses internal combined kernel only"
fi

# Shared native input builder must remain under Interop.
if [[ "$ROUTE_INPUT_BUFFER_SOURCE" == RunPlayCore/Sources/Interop/* ]]; then
  pass "shared native route-input builder remains under Interop"
else
  fail "shared native route-input builder left Interop"
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
