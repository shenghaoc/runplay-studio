#include "TestSupport.hpp"

#include <cstdlib>
#include <iostream>

static_assert(__cplusplus >= 202302L, "RunPlayEngineCpp must compile as C++23");

int main() {
    run_engine_info_tests();
    run_route_interop_tests();
    run_geodesy_tests();
    run_route_geometry_tests();
    run_route_quality_pipeline_tests();
    run_personal_heatmap_coverage_tests();
    run_route_alignment_dtw_tests();
    std::cout << "RunPlayEngineCppTests: all checks passed\n";
    return EXIT_SUCCESS;
}
