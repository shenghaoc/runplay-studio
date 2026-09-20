# Heart-Rate Training Load

RunPlay Studio computes a per-workout training load and a library-wide
fitness/fatigue/form model from it. Everything runs locally; nothing leaves
this Mac. This page explains what the numbers are, where they come from, and
where they stop being trustworthy.

**This is not medical guidance.** These are arithmetic models over recorded
heart-rate data. They know nothing about your health, and they are no
substitute for a coach or a clinician.

## Per-workout load: Banister TRIMP

The canonical load is Banister's TRIMP in its exponential form, summed over
the workout's recorded heart-rate intervals:

```text
TRIMP = Σ  minutes × HRreserve × y · e^(k × HRreserve)
HRreserve = (HR − resting) / (max − resting), clamped to [0, 1]
```

Each interval's heart rate is the mean of its two endpoint samples, and an
interval exists only between adjacent points inside one route segment — a
recording gap or a pause never contributes weight, matching the active-time
policy used everywhere else in the app. Intervals with a missing heart rate
on either endpoint count toward coverage but add no load. The computation is
a single native engine pass over the whole workout.

### The coefficient set

The two published coefficient pairs come from male and female study cohorts:
`y = 0.64, k = 1.92` and `y = 0.86, k = 1.67`. Settings offers the choice
without requiring it. The choice scales the magnitude of your loads more
than their shape, so fitness, fatigue, and form *trends* are largely
unaffected by picking the "wrong" one; absolute TRIMP values are only
comparable within one coefficient set.

### Zones

The secondary display buckets the same intervals into five zones by heart
rate. The default bounds are 60, 70, 80, and 90 percent of maximum heart
rate (zone 1 unbounded low); custom ascending bounds can be entered in
Settings. Zone time exists only for measured loads — zone minutes without a
strap would be invented data.

## Measured or estimated

A run counts as **measured** when valid heart-rate time covers at least
300 seconds *and* at least half of the workout's covered active time.
Below either floor the load is an **estimate** from pace and duration:

- Average pace maps onto an assumed heart-rate reserve — bands from 0.30
  (under 6 km/h) to a hard cap of 0.75 (above 14 km/h).
- Without usable pace either, a duration-only floor of 0.50 applies.

The estimator is deliberately conservative: the cap understates a hard
strapless effort rather than inflating it. Every estimate is labelled
"Estimated" wherever it appears, and the snapshot stores the assumed reserve
and the basis (pace/duration or duration-only) so the disclosure is exact.

## The athlete profile

Nothing in the profile is required. Blank fields derive:

- **Maximum heart rate**: a measured value always wins; otherwise the Tanaka
  estimate `208 − 0.7 × age` from birth year; otherwise a population default
  of 185 bpm. Whichever path produced it is disclosed.
- **Resting heart rate**: entered value, else a 60 bpm population default.
- **Zones**: custom bounds, else the default percentages above.

The profile is stored as local JSON beside your workout library.

### Stale loads

Every stored load records the profile it was computed with. A snapshot is
stale when that profile differs from the current one — the same rule that
covers a load that was never computed. Changing the profile never starts
silent background work: Settings shows how many runs would be recomputed and
"Recompute Training Loads" runs the same resumable, cancellable pass as the
one-time backfill.

## Fitness, fatigue, and form

The library model is the standard first-order daily recursion over the
scoped workouts' loads:

```text
CTL_d = CTL_{d−1} + (load_d − CTL_{d−1}) / τ_fitness      (default 42 days)
ATL_d = ATL_{d−1} + (load_d − ATL_{d−1}) / τ_fatigue      (default 7 days)
Form_d = CTL_d − ATL_d
```

CTL (fitness) is the chronic training load, ATL (fatigue) the acute one,
and form their same-day difference: positive form means the modeled fitness
background exceeds recent strain. The time constants are adjustable in the
Trends chart; they are presentation preferences and never rewrite stored
data.

### Estimated loads stay out of the model by default

A fitness/fatigue curve means something only if its inputs are comparable.
Estimated loads are invented values — conservative ones, but invented — and
including them by default would bias the curve downward, understating
fatigue, the direction that matters to someone training. So they don't:

- Estimated runs show lighter bars on the daily-load chart, clearly
  labelled, and are informative on their own.
- Days whose runs have no heart rate are marked as non-contributing —
  zero-contribution is not the same as a rest day, and the hover readout
  and spoken summaries say which is which.
- The chart discloses heart-rate coverage (measured days ÷ days with runs)
  for the displayed window, so the curve's trustworthiness is visible.
- People who mostly run without a strap can opt in on the Trends chart;
  the caveat is stated there and in Settings, not buried here.

### What an unknown-load day does to the model, and which way it lies

This is the model's sharpest edge, so it is stated plainly rather than left
to be inferred.

A day whose runs carry no usable heart rate has **no load the model can
use**. The recursion still runs for that day, with `load_d = 0`. That is
arithmetically identical to what a rest day does — and it is not the same
thing at all. A rest day is a *measured* zero: you did not run, and the
library has no workout record for it. An unknown-load day is an
*unmeasured* one: you did run, the library has the workout, and only the
heart rate is missing. The app can tell the two apart; the recursion
cannot.

The error this produces has a direction, and it is the unhelpful one:

- Fitness (CTL) **decays** across the stretch, as if the training had not
  happened. You read as less fit than you are.
- Fatigue (ATL) decays faster, because its time constant is shorter. You
  read as fresher than you are.
- Form is fitness minus fatigue, so it **rises** — the reading that says
  "you are rested, go hard" — precisely when the app has the least idea
  what you have been doing.

In short: **a stretch of strapless running reads as lost fitness and gained
freshness.** If you train by form, that is the direction that flatters a
hard-session decision instead of cautioning it.

Two things mitigate it, neither of which removes it:

- The Trends chart **shades** the span behind the fitness, fatigue, and
  form lines. The values are unchanged; the shading marks them as resting
  on input nobody recorded. The shading does not depend on the
  estimated-load opt-in — an invented value standing in for a missing
  measurement does not make the day measured.
- The heart-rate coverage percentage tells you how much of the window the
  curve is actually built on.

The bias also outlives the span. Once heart rate returns, the model is
correct again day by day, but it restarts from a state the gap pushed down,
and it takes on the order of the time constant — 42 days for fitness, 7 for
fatigue — to recover. A shaded fortnight is not a fortnight of doubt; it is
a fortnight of doubt plus a tail.

The honest fix is wearing the strap, not a better estimator.

## Limits

- Unknown-load days decay the model as if you had rested, so a stretch of
  strapless running reads as lost fitness and gained freshness, and the
  effect persists past the gap. The chart shades those spans; see above.
- TRIMP is one linear-ish summary of a nonlinear system. Two very different
  runs can share a value.
- The model knows only the runs in this library and this scope; it cannot
  see cycling, skiing, or anything you did before your first import.
- Time constants are conventions, not measurements of you — 42/7 is the
  literature default, not a personal truth.
- A heart-rate reserve built on estimated maximums inherits those estimate
  errors. Entering a measured maximum and resting value is the upgrade.

## Where things live

| Concern | Where |
| --- | --- |
| Interval TRIMP + zone buckets | native engine, one summary-only bulk call per measured pass |
| Interval construction, measured/estimated policy, estimator | `RunPlayCore` `TrainingLoadCalculator` |
| Profile derivation + persistence | `AthleteProfile`, `FileAthleteProfileStore` |
| Daily rollup + CTL/ATL/TSB | `TrainingLoadRollup` (Swift, per-day scalar work) |
| Chart, preferences, disclosures | Trends workspace |
| Profile editing + recompute | Settings (⌘,) |
