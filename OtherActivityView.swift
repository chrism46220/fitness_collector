//
//  OtherActivityView.swift
//  FitnessCollector
//
//  Provides interactive trends for the "Other" activity category. It mirrors the
//  behavior of LiftingActivityView but uses the .other category and appropriate
//  UI strings.
//

import SwiftUI

struct OtherActivityView: View {
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
            category: .other,
            trendsTitle: "Other Activity Trends",
            emptyMessage: "No other workouts found in Apple Health.",
            workoutNoun: "session",
            metrics: Self.metrics,
            showsMissingDataStates: true,
            emptyRangeMessage: "No other sessions in this range.",
            selectionSummary: { workout, unit, value in
                LiftingSelectionSummary(workout: workout, unit: unit, value: value)
            }
        )
    }
}
