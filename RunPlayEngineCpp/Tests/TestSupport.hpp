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
