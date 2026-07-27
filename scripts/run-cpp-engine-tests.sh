#!/usr/bin/env bash
# run-cpp-engine-tests.sh — build and run native RunPlayEngineCppTests
#
# Usage:
#   ./scripts/run-cpp-engine-tests.sh              # SPM build + run
#   ./scripts/run-cpp-engine-tests.sh --sanitize   # ASan + UBSan via clang++
#
# Sanitizer mode compiles the same engine sources and native test with clang++
# rather than forwarding -fsanitize through SPM's -Xlinker path. Apple's ld
# rejects -fsanitize when passed as a bare linker flag; the clang++ driver must
# own instrumentation and runtime linking.
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

# Prefer the active Swift toolchain's clang++ so macOS and Linux CI stay aligned.
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

if [[ "$SANITIZE" -eq 1 ]]; then
  echo "Building RunPlayEngineCppTests with AddressSanitizer + UndefinedBehaviorSanitizer..."
  echo "Compiler: $(${CXX_COMPILER[@]} --version | head -1)"
  OUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/runplay-engine-asan.XXXXXX")"
  OUT_BIN="${OUT_DIR}/RunPlayEngineCppTests"
  cleanup() { rm -rf "$OUT_DIR"; }
  trap cleanup EXIT

  export ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=1:halt_on_error=1}"
  export UBSAN_OPTIONS="${UBSAN_OPTIONS:-halt_on_error=1:print_stacktrace=1}"

  # On Apple platforms, leak detection via ASan is not always supported the same
  # way as on Linux; allow detect_leaks=0 if the runtime rejects it.
  if [[ "$(uname -s)" == "Darwin" ]]; then
    export ASAN_OPTIONS="${ASAN_OPTIONS/detect_leaks=1/detect_leaks=0}"
  fi

  "${CXX_COMPILER[@]}" \
    "$CXX_STD_FLAG" \
    "${WARNING_FLAGS[@]}" \
    -fsanitize=address \
    -fsanitize=undefined \
    -fno-omit-frame-pointer \
    -g \
    -O1 \
    -I "$ENGINE_INCLUDE" \
    "$ENGINE_SRC" \
    "$TEST_SRC" \
    -o "$OUT_BIN"

  echo "Running $OUT_BIN (ASan + UBSan)"
  "$OUT_BIN"
  echo "RunPlayEngineCppTests (sanitized) completed successfully"
  exit 0
fi

echo "Building RunPlayEngineCppTests via SwiftPM..."
swift build --product RunPlayEngineCppTests

BIN="$(swift build --show-bin-path --product RunPlayEngineCppTests)/RunPlayEngineCppTests"
if [[ ! -x "$BIN" ]]; then
  echo "error: expected executable at $BIN" >&2
  exit 1
fi

echo "Running $BIN"
"$BIN"
echo "RunPlayEngineCppTests completed successfully"
