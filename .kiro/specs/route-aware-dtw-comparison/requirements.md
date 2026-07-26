# Requirements: Route-Aware DTW Comparison

## Overview

Add an optional **Route-Aware** comparison alignment mode using constrained dynamic time warping over route geometry. Preserve the existing **Distance** alignment mode as the default.

## Requirements

### R1. Alignment modes
- The product exposes Distance and Route-Aware modes with those exact user-facing names.
- Distance remains the default after upgrading older application sessions.
- DTW is an implementation detail; UI copy says Route-Aware, not “DTW.”

### R2. Core alignment engine
- Pure `RunPlayCore` implementation with no SwiftUI/AppKit/MapKit/Accelerate/network dependency.
- Geometry-only cost (spatial separation, heading, progress, warp penalties).
- No pace/time/HR/elevation/cadence in alignment cost.
- Deterministic, cancellable, sample-budgeted, band-constrained DTW.

### R3. Gaps and blocks
- Alignment blocks never bridge source route segment gaps.
- Charts and map marker interpolation never cross blocks.

### R4. Mapping and metrics
- Slider in Route-Aware mode uses matched route progress, not either workout’s raw distance.
- Matched-section clocks start at the current block start anchor.
- Whole-workout summary, kilometre splits, and recorded laps remain independent of DTW.

### R5. View model
- Heavy work lives in `ComparisonViewModel`, not AppState computed properties.
- In-memory cache only; slider movement never recomputes DTW.
- Stale results from previous pairs never publish.

### R6. Session
- Persist alignment mode and selected distances/progress only.
- Version-1 sessions migrate to Distance + zero aligned progress.

### R7. Accessibility
- Mode, quality, coverage, progress, mapped distances, and separation are spoken.
- Announcements are retained and non-spammy.

### R8. Out of scope
- Map matching, cyclic loop rotation, opposite-direction cumulative-time alignment, DTW splits/laps, disk cache, cloud/AI.
