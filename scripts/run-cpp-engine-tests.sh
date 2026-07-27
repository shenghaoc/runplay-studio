#!/usr/bin/env bash
# run-cpp-engine-tests.sh — build and run native RunPlayEngineCppTests
#
# Usage:
#   ./scripts/run-cpp-engine-tests.sh              # normal clang++ build + run
#   ./scripts/run-cpp-engine-tests.sh --sanitize   # ASan + UBSan via clang++
#
# The native C++ test binary is compiled with clang++ on all platforms.
# SwiftPM's C++ executable target can fail on Linux with:
#   module 'RunPlayEngineCpp' is needed but has not been provided
# when a dependent target includes modular public headers under -fmodules with
# implicit modules disabled. Compiling the same sources with clang++ matches
# the intended C++23 warning policy and works on macOS and Linux CI.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SANITIZE=0
if [[ "${1:-}" == "--sanitize" ]]; then
  SANITIZE=1
fi

ENGINE_INCLUDE="RunPlayEngineCpp/include"
ENGINE_SRC="RunPlayEngineCpp/Sources/RunPlayEngine.cpp"
TEST_SRC="RunPlayEngineCpp/Tests/EngineInfoTests.cpp"

# Prefer the active toolchain's clang++ so macOS and Linux CI stay aligned.
if command -v clang++ >/dev/null 2>&1; then
  CXX_COMPILER=(clang++)
elif command -v c++ >/dev/null 2>&1; then
  CXX_COMPILER=(c++)
else
  echo "error: no C++ compiler (clang++ / c++) found on PATH" >&2
  exit 1
fi

# Match the package's typed C++23 setting (cxx2b → -std=c++2b on current
# toolchains; both c++2b and c++23 define __cplusplus as 202302L here).
CXX_STD_FLAG="-std=c++2b"
WARNING_FLAGS=(
  -Wall
  -Wextra
  -Wpedantic
  -Wconversion
  -Wsign-conversion
  -Wshadow
  -Werror
)

OUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/runplay-engine-tests.XXXXXX")"
OUT_BIN="${OUT_DIR}/RunPlayEngineCppTests"
cleanup() { rm -rf "$OUT_DIR"; }
trap cleanup EXIT

build_args=(
  "$CXX_STD_FLAG"
  "${WARNING_FLAGS[@]}"
  -g
  -I "$ENGINE_INCLUDE"
  "$ENGINE_SRC"
  "$TEST_SRC"
  -o "$OUT_BIN"
)

if [[ "$SANITIZE" -eq 1 ]]; then
  echo "Building RunPlayEngineCppTests with AddressSanitizer + UndefinedBehaviorSanitizer..."
  build_args+=(
    -fsanitize=address
    -fsanitize=undefined
    -fno-omit-frame-pointer
    -O1
  )
  export ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=1:halt_on_error=1}"
  export UBSAN_OPTIONS="${UBSAN_OPTIONS:-halt_on_error=1:print_stacktrace=1}"
  # ASan leak detection is not uniformly available on Apple platforms.
  if [[ "$(uname -s)" == "Darwin" ]]; then
    export ASAN_OPTIONS="${ASAN_OPTIONS/detect_leaks=1/detect_leaks=0}"
  fi
else
  echo "Building RunPlayEngineCppTests with clang++..."
  build_args+=(-O0)
fi

echo "Compiler: $(${CXX_COMPILER[@]} --version | head -1)"
"${CXX_COMPILER[@]}" "${build_args[@]}"

echo "Running $OUT_BIN"
"$OUT_BIN"
if [[ "$SANITIZE" -eq 1 ]]; then
  echo "RunPlayEngineCppTests (sanitized) completed successfully"
else
  echo "RunPlayEngineCppTests completed successfully"
fi
