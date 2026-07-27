#include "RunPlayEngineCpp/RunPlayEngine.hpp"

namespace runplay {

EngineInfo engine_info() noexcept {
    return EngineInfo{
        /*.abi_version=*/1u,
        /*.language_standard=*/"C++23",
    };
}

}  // namespace runplay
