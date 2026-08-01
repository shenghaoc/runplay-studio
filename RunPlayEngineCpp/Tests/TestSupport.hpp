#pragma once

#include <cstdlib>
#include <iostream>

inline void expect(bool condition, const char* message) {
    if (!condition) {
        std::cerr << "FAIL: " << message << '\n';
        std::exit(EXIT_FAILURE);
    }
}

void run_engine_info_tests();
void run_route_interop_tests();
void run_geodesy_tests();
void run_route_geometry_tests();
void run_route_quality_pipeline_tests();
void run_personal_heatmap_coverage_tests();
void run_route_alignment_dtw_tests();
void run_segment_detection_tests();
void run_elevation_profile_tests();
void run_route_metric_scale_bucket_tests();
