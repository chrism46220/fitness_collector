//
//  ActivityStatistics.swift
//  FitnessCollector
//
//  Aggregate rollups for the fitness overview. Pure functions over WorkoutRow
//  arrays so the numbers shown on Level 1 can be unit tested without HealthKit.
//

import Foundation

/// Aggregate statistics for one activity category, or for all activity.
struct ActivityStatistics: Equatable {
    var workoutCount: Int
    var totalDurationMinutes: Double
    var totalCalories: Double
    var totalDistanceMiles: Double
    var averageHeartRate: Double?
    var lastWorkoutDate: Date?

    static let empty = ActivityStatistics(
        workoutCount: 0,
        totalDurationMinutes: 0,
        totalCalories: 0,
        totalDistanceMiles: 0,
        averageHeartRate: nil,
        lastWorkoutDate: nil
    )

    /// True when there is nothing worth rendering.
    var isEmpty: Bool { workoutCount == 0 }

    /// Sums the workouts, skipping measurements HealthKit did not supply.
    ///
    /// Missing values are never substituted with zero in the per-workout sense:
    /// a workout without a distance reading contributes nothing to
    /// `totalDistanceMiles`, and if no workout has a heart-rate reading the
    /// average stays `nil` rather than being reported as 0 bpm.
    static func make(from workouts: [WorkoutRow]) -> ActivityStatistics {
        guard !workouts.isEmpty else { return .empty }

        let totalDuration = workouts.reduce(0.0) { $0 + $1.durationMinutes }
        let totalCalories = workouts.reduce(0.0) { $0 + ($1.calories ?? 0) }
        let totalDistance = workouts.reduce(0.0) { $0 + ($1.distanceMiles ?? 0) }

        let heartRates = workouts.compactMap(\.averageHeartRate)
        let averageHeartRate = heartRates.isEmpty
            ? nil
            : heartRates.reduce(0, +) / Double(heartRates.count)

        return ActivityStatistics(
            workoutCount: workouts.count,
            totalDurationMinutes: totalDuration,
            totalCalories: totalCalories,
            totalDistanceMiles: totalDistance,
            averageHeartRate: averageHeartRate,
            lastWorkoutDate: workouts.map(\.start).max()
        )
    }
}

extension Array where Element == WorkoutRow {
    /// Workouts belonging to `category`, newest first.
    func inCategory(_ category: ActivityCategory) -> [WorkoutRow] {
        filter { $0.category == category }
            .sorted { $0.start > $1.start }
    }
}
