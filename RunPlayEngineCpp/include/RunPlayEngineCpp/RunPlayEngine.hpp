#pragma once

#include <cstdint>
#include <string>

namespace runplay {

/// Portable engine build / ABI identity for the C++ computational core.
///
/// This smoke type exists only to prove public-header discovery, C++23
/// compilation, standard-library interoperability, and a noexcept Swift
/// boundary. Production algorithms are not present yet.
struct EngineInfo final {
    std::uint32_t abi_version;
    std::string language_standard;
};

/// Returns deterministic engine identity for the current build.
///
/// Always reports ABI version 1 and the C++23 language-standard identifier.
/// Never throws.
[[nodiscard]]
EngineInfo engine_info() noexcept;

}  // namespace runplay
