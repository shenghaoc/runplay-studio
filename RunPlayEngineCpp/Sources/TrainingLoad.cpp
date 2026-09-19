#include "RunPlayEngineCpp/TrainingLoad.hpp"

#include <cmath>

namespace runplay {
namespace {

[[nodiscard]] bool is_finite_positive(double value) noexcept {
    return std::isfinite(value) && value > 0.0;
}

[[nodiscard]] bool policy_is_valid(const TrainingLoadPolicy& policy) noexcept {
    if (!is_finite_positive(policy.resting_heart_rate_bpm)
        || !is_finite_positive(policy.maximum_heart_rate_bpm)) {
        return false;
    }
    if (policy.resting_heart_rate_bpm >= policy.maximum_heart_rate_bpm) {
        return false;
    }
    if (!is_finite_positive(policy.coefficient_multiplier)) {
        return false;
    }
    if (!is_finite_positive(policy.coefficient_exponent)) {
        return false;
    }
    if (!std::isfinite(policy.zone1_lower_bound_bpm)
        || !std::isfinite(policy.zone2_lower_bound_bpm)
        || !std::isfinite(policy.zone3_lower_bound_bpm)
        || !std::isfinite(policy.zone4_lower_bound_bpm)
        || !std::isfinite(policy.zone5_lower_bound_bpm)) {
        return false;
    }
    return policy.zone1_lower_bound_bpm < policy.zone2_lower_bound_bpm
        && policy.zone2_lower_bound_bpm < policy.zone3_lower_bound_bpm
        && policy.zone3_lower_bound_bpm < policy.zone4_lower_bound_bpm
        && policy.zone4_lower_bound_bpm < policy.zone5_lower_bound_bpm;
}

/// A zeroed summary carrying only the failure status — an error path must
/// never leak partial accumulations.
[[nodiscard]] TrainingLoadSummary error_summary(TrainingLoadStatus status) noexcept {
    TrainingLoadSummary summary;
    summary.status = status;
    return summary;
}

/// Zone index for one rate: the count of lower bounds at or below it, floored
/// at 1 (zone 1 is the unbounded-low bucket) and capped at 5.
[[nodiscard]] std::size_t zone_index(
    double heart_rate_bpm,
    const TrainingLoadPolicy& policy
) noexcept {
    std::size_t index = 1;
    if (heart_rate_bpm >= policy.zone2_lower_bound_bpm) {
        index = 2;
    }
    if (heart_rate_bpm >= policy.zone3_lower_bound_bpm) {
        index = 3;
    }
    if (heart_rate_bpm >= policy.zone4_lower_bound_bpm) {
        index = 4;
    }
    if (heart_rate_bpm >= policy.zone5_lower_bound_bpm) {
        index = 5;
    }
    return index;
}

}  // namespace

TrainingLoadSummary compute_training_load(
    const TrainingLoadSample* samples,
    std::size_t sample_count,
    TrainingLoadPolicy policy
) noexcept {
    TrainingLoadSummary summary;

    if (sample_count > 0 && samples == nullptr) {
        summary.status = TrainingLoadStatus::invalid_input_buffer;
        return summary;
    }
    if (!policy_is_valid(policy)) {
        summary.status = TrainingLoadStatus::invalid_policy;
        return summary;
    }

    const double reserve_span =
        policy.maximum_heart_rate_bpm - policy.resting_heart_rate_bpm;

    double weighted_rate_sum = 0.0;
    for (std::size_t index = 0; index < sample_count; ++index) {
        const TrainingLoadSample& sample = samples[index];
        if (!std::isfinite(sample.weight_seconds) || sample.weight_seconds < 0.0) {
            return error_summary(TrainingLoadStatus::invalid_input_contract);
        }
        if (sample.has_heart_rate > 1) {
            return error_summary(TrainingLoadStatus::invalid_input_contract);
        }

        summary.total_interval_count += 1;
        summary.covered_seconds += sample.weight_seconds;
        if (sample.has_heart_rate == 0) {
            continue;
        }
        if (!std::isfinite(sample.heart_rate_bpm) || sample.heart_rate_bpm <= 0.0) {
            return error_summary(TrainingLoadStatus::invalid_input_contract);
        }

        double reserve =
            (sample.heart_rate_bpm - policy.resting_heart_rate_bpm) / reserve_span;
        if (reserve < 0.0) {
            reserve = 0.0;
        } else if (reserve > 1.0) {
            reserve = 1.0;
        }

        summary.valid_heart_rate_seconds += sample.weight_seconds;
        summary.valid_interval_count += 1;

        const double weighted_rate =
            sample.heart_rate_bpm * sample.weight_seconds;
        weighted_rate_sum += weighted_rate;

        const double zone_seconds_increment = sample.weight_seconds;
        switch (zone_index(sample.heart_rate_bpm, policy)) {
        case 1: summary.zone1_seconds += zone_seconds_increment; break;
        case 2: summary.zone2_seconds += zone_seconds_increment; break;
        case 3: summary.zone3_seconds += zone_seconds_increment; break;
        case 4: summary.zone4_seconds += zone_seconds_increment; break;
        case 5: summary.zone5_seconds += zone_seconds_increment; break;
        default: break;
        }

        const double minutes = sample.weight_seconds / 60.0;
        const double exponential =
            std::exp(policy.coefficient_exponent * reserve);
        const double scaled_reserve = reserve * policy.coefficient_multiplier;
        const double contribution = minutes * scaled_reserve * exponential;
        summary.total_trimp += contribution;
    }

    if (summary.valid_heart_rate_seconds > 0.0) {
        summary.mean_heart_rate_bpm =
            weighted_rate_sum / summary.valid_heart_rate_seconds;
        summary.has_mean_heart_rate = 1;
    }
    summary.status = TrainingLoadStatus::success;
    return summary;
}

}  // namespace runplay
