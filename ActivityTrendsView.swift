import SwiftUI

enum ChartRange: String, CaseIterable {
    case seven = "7D"
    case thirty = "30D"
    case ninety = "90D"
    case all = "All"
}

/// Describes a per-workout series without coupling charts to an activity category.
struct WorkoutMetric: Identifiable {
    let id: String
    let title: String
    let unit: String
    let value: (WorkoutRow) -> Double?
}

struct ActivityTrendsView<SelectionSummary: View>: View {
    @ObservedObject var health: HealthKitManager
    let category: ActivityCategory
    let trendsTitle: String
    let emptyMessage: String
    let workoutNoun: String
    let metrics: [WorkoutMetric]
    @ViewBuilder let selectionSummary: (WorkoutRow, String, Double?) -> SelectionSummary
    @State private var chartRange: ChartRange = .thirty
    @State private var selectedWorkout: WorkoutRow?

    private var workouts: [WorkoutRow] {
        health.workouts
            .filter { $0.category == category }
            .sorted { $0.start < $1.start }
    }

    private var chartWorkouts: [WorkoutRow] {
        guard chartRange != .all else { return workouts }

        let days: Int = switch chartRange {
        case .seven: 7
        case .thirty: 30
        case .ninety: 90
        case .all: 0
        }

        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -days,
            to: Date()
        ) ?? Date()

        return workouts.filter { $0.start >= cutoff }
    }

    var body: some View {
        VStack(spacing: 0) {
            if health.statusMessage != "Not connected" {
                Text(health.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.bottom, 6)
            }

            List {
                if !workouts.isEmpty {
                    Section(trendsTitle) {
                        Picker("Range", selection: $chartRange) {
                            ForEach(ChartRange.allCases, id: \.self) { range in
                                Text(range.rawValue).tag(range)
                            }
                        }
                        .pickerStyle(.segmented)

                        ForEach(metrics) { metric in
                            WorkoutMetricChart(
                                title: metric.title,
                                unit: metric.unit,
                                workouts: chartWorkouts,
                                chartRange: chartRange,
                                value: metric.value,
                                onSelectWorkout: { selectedWorkout = $0 },
                                workoutNoun: workoutNoun,
                                selectionSummary: selectionSummary
                            )
                        }
                    }
                } else {
                    Section(trendsTitle) {
                        Text(emptyMessage)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Workouts") {
                    ForEach(workouts.reversed()) { workout in
                        NavigationLink {
                            WorkoutDetailView(workout: workout.hkWorkout, summary: workout, health: health)
                        } label: {
                            WorkoutRowView(workout: workout)
                        }
                    }
                }
            }
        }
        .sheet(item: $selectedWorkout) { workout in
            NavigationStack {
                WorkoutDetailView(
                    workout: workout.hkWorkout,
                    summary: workout,
                    health: health
                )
            }
        }
    }
}
