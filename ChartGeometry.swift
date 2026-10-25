//
//  ChartGeometry.swift
//  FitnessCollector
//
//  Pure chart/pace geometry extracted from ContentView.swift so it can be
//  exercised by unit tests without a hosting SwiftUI view.
//
//  Behaviour is intentionally identical to the original implementations;
//  these functions are value-in/value-out and touch no view or HealthKit state.
//

import Foundation

/// Centred rolling-average smoothing for GPS-derived pace samples.
enum PaceSmoothing {

    /// Minimum sample count below which smoothing is skipped entirely.
    static let minimumSampleCount = 15

    /// Half-width of the centred window, in samples.
    static let halfWindow = 20

    /// Applies a centred rolling average to damp GPS noise while preserving
    /// genuine slowdowns and stops. Inputs shorter than
    /// `minimumSampleCount` are returned unchanged.
    static func smooth(_ samples: [PaceSample]) -> [PaceSample] {
        guard samples.count >= minimumSampleCount else { return samples }

        return samples.enumerated().map { index, sample in
            let start = max(0, index - halfWindow)
            let end = min(samples.count - 1, index + halfWindow)
            let window = samples[start...end]
            let average = window.map { $0.paceMinutesPerMile }.reduce(0, +) / Double(window.count)

            return PaceSample(
                minutesFromStart: sample.minutesFromStart,
                paceMinutesPerMile: average
            )
        }
    }
}

/// Y-axis domain and tick computation for a metric chart.
enum ChartGeometry {

    /// Default number of horizontal gridlines/labels.
    static let defaultTickCount = 4

    /// Computes a padded display range covering every finite value produced by
    /// `value`. Falls back to `0...1` when nothing is plottable.
    ///
    /// - Padding is 15% of the value range, with a floor of 5% of the largest
    ///   absolute value, never less than 1.0.
    /// - The lower bound is clamped at zero: pace and heart rate cannot be
    ///   negative, so negative headroom would waste plot space.
    static func yDomain<T>(_ items: [T], value: (T) -> Double?) -> ClosedRange<Double> {
        let values = items.compactMap(value).filter { $0.isFinite }

        guard let minValue = values.min(),
              let maxValue = values.max() else {
            return 0...1
        }

        let range = maxValue - minValue
        let padding = max(range * 0.15, max(abs(maxValue) * 0.05, 1.0))
        let lower = max(0, minValue - padding)
        let upper = maxValue + padding

        if lower >= upper {
            return max(0, lower - 1)...(upper + 1)
        }

        return lower...upper
    }

    /// Evenly spaces `tickCount` ticks across `domain`, including both bounds.
    ///
    /// A tick count of 1 or less degenerates to a single tick at the lower
    /// bound.
    static func tickValues(in domain: ClosedRange<Double>,
                           tickCount: Int = defaultTickCount) -> [Double] {
        let lower = domain.lowerBound
        let upper = domain.upperBound

        guard tickCount > 1 else { return [lower] }

        let step = (upper - lower) / Double(tickCount - 1)
        return (0..<tickCount).map { lower + Double($0) * step }
    }

    /// Returns the item whose timestamp is closest to `date`.
    ///
    /// Ties resolve to whichever item appears first in `items`, matching
    /// `min(by:)` semantics.
    static func closestItem<T>(to date: Date,
                               in items: [T],
                               timestamp: (T) -> Date) -> T? {
        items.min(by: {
            abs(timestamp($0).timeIntervalSince(date)) <
            abs(timestamp($1).timeIntervalSince(date))
        })
    }
}
