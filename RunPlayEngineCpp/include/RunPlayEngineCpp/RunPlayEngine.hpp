#pragma once

#include <cstdint>

#include "RunPlayEngineCpp/ElevationProfile.hpp"
#include "RunPlayEngineCpp/Geodesy.hpp"
#include "RunPlayEngineCpp/PersonalHeatmapCoverage.hpp"
#include "RunPlayEngineCpp/RouteAlignmentDtw.hpp"
#include "RunPlayEngineCpp/RouteGeometry.hpp"
#include "RunPlayEngineCpp/RouteInterop.hpp"
#include "RunPlayEngineCpp/RouteQualityPipeline.hpp"
#include "RunPlayEngineCpp/SegmentDetection.hpp"

namespace runplay {

/// Language level used to compile the portable engine.
enum class LanguageStandard : std::uint8_t {
    cpp23,
};

/// Portable engine build / ABI identity for the C++ computational core.
///
/// This smoke type exists only to prove public-header discovery, C++23
/// compilation, value interoperability, and a noexcept Swift boundary.
/// It is allocation-free so constructing it cannot terminate because of an
/// allocation failure inside the noexcept boundary.
struct EngineInfo final {
    std::uint32_t abi_version;
    LanguageStandard language_standard;
    std::uint64_t cpp_language_value;
};

/// Returns deterministic engine identity for the current build.
///
/// Always reports ABI version 1, the C++23 identifier, and the compiler's
/// `__cplusplus` value. Never throws or allocates.
[[nodiscard]]
EngineInfo engine_info() noexcept;

}  // namespace runplay
