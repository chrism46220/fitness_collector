import SwiftUI

struct LiftingActivityView: View {
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
            category: .lifting,
            trendsTitle: "Lifting Trends",
            emptyMessage: "No strength workouts found in Apple Health.",
            workoutNoun: "session",
            metrics: Self.metrics,
            showsMissingDataStates: true,
            emptyRangeMessage: "No lifting sessions in this range.",
            selectionSummary: { workout, unit, value in
                LiftingSelectionSummary(workout: workout, unit: unit, value: value)
            }
        )
    }
}

struct LiftingSelectionSummary: View {
    let workout: WorkoutRow
    let unit: String
    let value: Double?

    var body: some View {
        VStack(alignment: .leading) {
            Text(workout.start.formatted(date: .abbreviated, time: .shortened))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("Session Time: \(formatDuration(workout.durationMinutes)) min")

            if let value {
                Text("\(unit): \(unit == "Minutes" ? formatDuration(value) : String(format: "%.0f", value))")
                    .font(.headline)
            }

            if let calories = workout.calories {
                Text("Active Calories: \(formatCalories(calories)) kcal")
            }

            if let hr = workout.averageHeartRate {
                Text("Avg HR: \(formatHeartRate(hr)) bpm")
            }

            if let maxHR = workout.maxHeartRate {
                Text("Max HR: \(formatHeartRate(maxHR)) bpm")
            }
        }
    }
}
