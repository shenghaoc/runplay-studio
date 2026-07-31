# Design: Remaining Core Hotspot Profile (final)

## Architecture

Follows the Personal Heatmap profiler pattern, extended for multi-family coverage.

### Components

| Component | Role |
|---|---|
| `RemainingCoreHotspotProfile` | XCTest driver; one method per family; no aggregator |
| `Profiling/HotspotProfilingSupport.swift` | `ContinuousClock` stats, accounting, memory snapshots, family filter |
| `Profiling/HotspotProfilingFixtures.swift` | Deterministic A/B/C/D/E synthetic fixtures |
| `Profiling/HotspotProfilingDigests.swift` | Exact Mode A/B digests (import digests omit minted UUIDs) |
| `Profiling/FITProfilingFixtureBuilder.swift` | Reuses `FITMultiSessionFixtureBuilder` |
| `RemainingPlatformHotspotProfile` | Map-line coalescing + Strava archive path |
| `scripts/run-remaining-core-hotspot-profile.sh` | Release build, Core + Platform invocation, nonzero on failure |

### Production-equivalent Mode A / Mode B

For decomposed candidates, production entry points gain **internal** profiled
twins (`analyzeCollectingProfile`, `normalizeAndAnalyzeCollectingProfile`,
`buildCollectingProfile`, `alignCollectingProfile`) that:

1. share the same implementation as the public path;
2. read `ContinuousClock` only when the profiled entry is used;
3. produce pure-Swift phase timing structs (no C++ types);
4. are referenced only from tests (enforced by `validate-cpp-boundaries.sh`).

Production public entry points pass a `nil` profile pointer and perform no clock
reads on the measurement path.

### Nested phases

Sample-builder subphases are nested under the sample-builder total and are not
double-counted in top-level accounting. Elevation inside route quality for
`normalizeAndAnalyze` is attributed to the route-quality phase, not re-added.

### Duplicate execution prevention

- No `testAllFamilies`.
- Each family method records `ProfileFamilyInvocationCounter` once.
- Family filter (`RUNPLAY_PROFILE_FAMILY`) returns early without work when unmatched.

### Statistics

| Size | Warm-ups | Measured |
|---|---:|---:|
| standard | 5 | 20 |
| large | 2 | 5 |
| productLimit | 1 | 3 |

Report median / p90 / min / max. Fixture generation is outside the measured region.

### Parity

Mode A output digest == Mode B output digest for every decomposed fixture.
Import parity uses digests that exclude freshly minted workout/point IDs while
retaining all computational fields.

### Accounting and overhead

```
unaccountedFraction = (ModeB_wall − top_level_phase_sum) / ModeB_wall
|unaccountedFraction| ≤ 0.05 required to publish attribution

overhead = ModeB_median / ModeA_median
overhead ≤ 1.15 preferred; above that, phase % marked approximate
```

### Memory

Darwin: resident before/after + process high-water via `mach_task_basic_info`.
Labels state process-wide high-water is not a sampled per-op peak unless a
separate memory mode samples mid-operation. Linux compiles with zero stubs.

### Importer fixtures

- JSON / GPX / TCX generated as UTF-8 text in-process.
- FIT binaries from `FITMultiSessionFixtureBuilder` (shared encoder).
- Strava ZIP via ZIPFoundation in Platform tests.
- XML parse+build reported as one combined phase (interleaved in production).

### Scoring and roadmap

Eleven-dimension 0–5 rubric with explicit disqualifiers and thresholds.
Final selected next phase is **SegmentDetector**, not MovementProfile-first:
segments dominate large/product-limit analysis wall; MovementProfile is a small
share. Full ranking and phase counts live in `docs/phase-plan.md` and the PR body.

## Environment variables

| Variable | Meaning |
|---|---|
| `RUNPLAY_CORE_HOTSPOT_PROFILE=1` | Enable harness (otherwise skip) |
| `RUNPLAY_PROFILE_FAMILY` | `all` / `analysis` / `alignment` / `metrics` / `import` / `comparison` |
| `RUNPLAY_PROFILE_PRODUCT_LIMIT=1` | A7 + C5 one-million-point probes |
| `RUNPLAY_PROFILE_MEMORY=1` | Extra memory rows |

## Non-goals

No production algorithm, C++ API, schema, importer behavior, UI, or resource-limit
change. No migration implementation on this branch.
