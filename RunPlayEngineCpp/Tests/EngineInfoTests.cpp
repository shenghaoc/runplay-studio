#include "RunPlayEngineCpp/RunPlayEngine.hpp"
#include "TestSupport.hpp"

#include <type_traits>

static_assert(
    noexcept(runplay::engine_info()),
    "engine_info must be declared noexcept for the Swift boundary");
static_assert(
    std::is_trivially_copyable_v<runplay::EngineInfo>,
    "EngineInfo must remain allocation-free and trivially copyable");

void run_engine_info_tests() {
    const runplay::EngineInfo first = runplay::engine_info();
    expect(first.abi_version == 1u, "abi_version must be 1");
    expect(
        first.language_standard == runplay::LanguageStandard::cpp23,
        "language_standard must identify C++23");
    expect(
        first.cpp_language_value >= 202302u,
        "cpp_language_value must report ISO C++23 or newer");

    const runplay::EngineInfo second = runplay::engine_info();
    expect(second.abi_version == first.abi_version, "abi_version must be deterministic");
    expect(
        second.language_standard == first.language_standard,
        "language_standard must be deterministic");
    expect(
        second.cpp_language_value == first.cpp_language_value,
        "cpp_language_value must be deterministic");

    // Confirm the free function itself is noexcept-invocable (runtime mirror of
    // the static_assert above).
    expect(
        noexcept(runplay::engine_info()),
        "engine_info must remain noexcept at the call site");
}
