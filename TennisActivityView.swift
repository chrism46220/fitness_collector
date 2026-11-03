//
//  TennisActivityView.swift
//  FitnessCollector
//
//  Provides interactive trends for tennis workouts, reusing the shared
//  ActivityTrendsView implementation. The layout, gestures and preset range
//  handling are identical to Running and Lifting.
//

import SwiftUI

struct TennisActivityView: View {
    @ObservedObject var health: HealthKitManager

    static let metrics: [WorkoutMetric] = [
        WorkoutMetric(id: "duration", title: "Session Duration", unit: "Minutes", value: { $0.durationMinutes }),
        WorkoutMetric(id: "calories", title: "Active Calories", unit: "kcal", value: { $0.calories }),
        WorkoutMetric(id: "averageHeartRate", title: "Average Heart Rate", unit: "BPM", value: { $0.averageHeartRate }),
        WorkoutMetric(id: "maxHeartRate", title: "Max Heart Rate", unit: "BPM", value: { $0.maxHeartRate })
    ]

    var body: some View {
        ActivityTrendsView(
            health: health,
            category: .tennis,
            trendsTitle: "Tennis Trends",
            emptyMessage: "No tennis workouts found in Apple Health.",
            workoutNoun: "session",
            metrics: Self.metrics,
            showsMissingDataStates: true,
            showsEmptyRangeCharts: true,
            emptyRangeMessage: "No tennis sessions in this range.",
            selectionSummary: { workout, unit, value in
                LiftingSelectionSummary(workout: workout, unit: unit, value: value)
            }
        )
    }
}
