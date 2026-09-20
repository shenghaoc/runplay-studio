import Foundation
import RunPlayCore

/// A contiguous stretch of days whose load input is unknown: runs happened,
/// but none of them carried usable heart rate.
///
/// `start` is the first unknown day's local day start and `endExclusive` is
/// one day past the last, so a single-day span still covers a full day of
/// chart width.
struct TrainingLoadUncertaintySpan: Equatable, Hashable {
    let start: Date
    let endExclusive: Date
    let dayCount: Int
}

/// Which stretches of the fitness/fatigue/form curve rest on input nobody
/// recorded.
///
/// The model integrates a `noHRData` day as zero, which is arithmetically
/// identical to a rest day — but the two are not equally *known*. A rest day
/// is a measured zero; an unknown-load day is an unmeasured one, and the app
/// can tell them apart because one has no workout record and the other has
/// one. Drawing a confident solid line through the second contradicts the
/// convention the rest of the app holds (gaps, not zeros; "—", not
/// placeholders), so the chart shades these spans instead.
///
/// The bias has a direction worth naming: treating unknown load as zero
/// decays fitness and sheds fatigue exactly as rest would, so a stretch of
/// strapless running reads as lost fitness and gained freshness — the
/// direction that flatters a training decision rather than cautioning it.
enum TrainingLoadUncertainty {
    /// Merges consecutive unknown-load days into spans, in chart order.
    ///
    /// Consecutive means adjacent in `loadDays`, which the rollup emits as a
    /// dense day-by-day series, so any `hrDay` or `restDay` between two
    /// unknown days ends the span. The spans do not depend on the
    /// estimated-load opt-in: opting in changes what the model does with an
    /// unmeasured day, not whether it was measured.
    static func spans(in loadDays: [TrainingLoadDay]) -> [TrainingLoadUncertaintySpan] {
        var spans: [TrainingLoadUncertaintySpan] = []
        var index = loadDays.startIndex
        while index < loadDays.endIndex {
            guard loadDays[index].contribution == .noHRData else {
                index += 1
                continue
            }
            let startIndex = index
            while index < loadDays.endIndex,
                  loadDays[index].contribution == .noHRData {
                index += 1
            }
            // `index` now sits one past the span. Prefer the next day's own
            // day start as the exclusive end so the rectangle lands on the
            // rollup's calendar rather than a nominal 24 hours — day lengths
            // vary across a DST transition.
            let lastIndex = index - 1
            let endExclusive: Date
            if index < loadDays.endIndex {
                endExclusive = loadDays[index].date
            } else {
                endExclusive = loadDays[lastIndex].date.addingTimeInterval(86_400)
            }
            spans.append(
                TrainingLoadUncertaintySpan(
                    start: loadDays[startIndex].date,
                    endExclusive: endExclusive,
                    dayCount: lastIndex - startIndex + 1
                )
            )
        }
        return spans
    }

    /// The shading's explanation, which has to differ by mode.
    ///
    /// With estimates excluded, every shaded day contributes nothing and the
    /// decay-as-rest sentence is exactly true. With estimates opted in, a
    /// shaded day carrying an estimate does contribute — an invented value —
    /// while one without an estimate still decays as rest. Saying only the
    /// first in both modes would describe the chart wrongly in one of them.
    static func biasCopy(includesEstimatedLoads: Bool) -> String {
        if includesEstimatedLoads {
            return """
                Shaded spans are days with runs but no usable heart rate. Where \
                an estimate stands in for one it is an invented value; where \
                none does, the model decays as if you had rested. The values \
                are unchanged — only the confidence is shown.
                """
        }
        return """
            Shaded spans are days with runs but no usable heart rate. The model \
            has no load for them and decays as if you had rested, so a stretch \
            of strapless running reads as lost fitness and gained freshness. \
            The values are unchanged — only the confidence is shown.
            """
    }
}
