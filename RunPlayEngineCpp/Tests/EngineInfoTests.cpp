// Native C++ tests for the RunPlayEngineCpp smoke API.
//
// No external test framework: assert and process exit status only.
// Built as the RunPlayEngineCppTests executable target.

#include "RunPlayEngineCpp/RunPlayEngine.hpp"

#include <cstdlib>
#include <iostream>
#include <string>

// C++23: ISO value is 202302L. Apple Clang / libc++ report this for both
// -std=c++23 and the SPM-typed cxx2b mode (-std=c++2b).
static_assert(__cplusplus >= 202302L, "RunPlayEngineCpp must compile as C++23");

static_assert(
    noexcept(runplay::engine_info()),
    "engine_info must be declared noexcept for the Swift boundary");

namespace {

void expect(bool condition, const char *message) {
    if (!condition) {
        std::cerr << "FAIL: " << message << '\n';
        std::exit(EXIT_FAILURE);
    }
}

}  // namespace

int main() {
    const runplay::EngineInfo first = runplay::engine_info();
    expect(first.abi_version == 1u, "abi_version must be 1");
    expect(first.language_standard == "C++23", "language_standard must identify C++23");

    const runplay::EngineInfo second = runplay::engine_info();
    expect(second.abi_version == first.abi_version, "abi_version must be deterministic");
    expect(
        second.language_standard == first.language_standard,
        "language_standard must be deterministic");

    // Confirm the free function itself is noexcept-invocable (runtime mirror of
    // the static_assert above).
    expect(
        noexcept(runplay::engine_info()),
        "engine_info must remain noexcept at the call site");

    std::cout << "RunPlayEngineCppTests: all checks passed "
              << "(abi=" << first.abi_version
              << ", std=" << first.language_standard
              << ", __cplusplus=" << __cplusplus << ")\n";
    return EXIT_SUCCESS;
}
