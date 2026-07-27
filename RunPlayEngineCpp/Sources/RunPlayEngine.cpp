#include "RunPlayEngineCpp/RunPlayEngine.hpp"

namespace runplay {

EngineInfo engine_info() noexcept {
    return EngineInfo{
        /*.abi_version=*/1u,
        /*.language_standard=*/LanguageStandard::cpp23,
        /*.cpp_language_value=*/static_cast<std::uint64_t>(__cplusplus),
    };
}

}  // namespace runplay
