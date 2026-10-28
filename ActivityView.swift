//
//  ActivityView.swift
//  FitnessCollector
//
//  LEVEL 2 — Activity view. One screen per ActivityCategory.
//
//  Running and Lifting share interactive trends. Other categories
//  get category-appropriate summaries and a workout history list. Every metric
//  shown is read from HealthKit; nothing is inferred or fabricated.
//

import SwiftUI

struct ActivityView: View {
    let category: ActivityCategory
    @ObservedObject var health: HealthKitManager

    private var workoutsNewestFirst: [WorkoutRow] {
        health.workouts.inCategory(category)
    }

    private var stats: ActivityStatistics {
        ActivityStatistics.make(from: workoutsNewestFirst)
    }

    var body: some View {
        Group {
            if category == .running {
                RunningActivityView(health: health)
            } else if category == .lifting {
                LiftingActivityView(health: health)
            } else {
                genericActivityList
            }
        }
        .navigationTitle(category.title)
        .navigationBarTitleDisplayMode(.large)
    }

    // MARK: - Generic categories

    private var genericActivityList: some View {
        List {
            Section {
                CategorySummaryCard(
                    category: category,
                    stats: stats
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            if workoutsNewestFirst.isEmpty {
                Section("Workouts") {
                    Text(emptyMessage)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Workouts") {
                    ForEach(workoutsNewestFirst) { workout in
                        NavigationLink {
                            WorkoutDetailView(
                                workout: workout.hkWorkout,
                                summary: workout,
                                health: health
                            )
                        } label: {
                            WorkoutRowView(workout: workout)
                        }
                    }
                }
            }
        }
    }

    private var emptyMessage: String {
        switch category {
        case .lifting:
            return "No strength workouts found in Apple Health."
        case .tennis:
            return "No tennis workouts found in Apple Health."
        case .other:
            return "No other workouts found in Apple Health."
        case .running:
            return "No running workouts found in Apple Health."
        }
    }
}

// MARK: - Category summary

private struct CategorySummaryCard: View {
    let category: ActivityCategory
    let stats: ActivityStatistics

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: category.symbolName)
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.title)
                        .font(.headline)
                    Text(category.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if stats.isEmpty {
                Text("No data yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: 0) {
                    column("\(stats.workoutCount)", "Workouts")
                    column(formatDuration(stats.totalDurationMinutes), "Total Time")
                    column(caloriesText, "Calories")
                }

                if let distanceText {
                    HStack(alignment: .top, spacing: 0) {
                        column(distanceText, "Miles")
                        column(heartRateText, "Avg HR")
                        emptyColumn()
                    }
                } else {
                    HStack(alignment: .top, spacing: 0) {
                        column(heartRateText, "Avg HR")
                        column(lastWorkoutText, "Last")
                        emptyColumn()
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.vertical, 6)
    }

    /// Renders an empty grid cell so three-column rows keep equal widths.
    /// Replaces a String constant that shadowed the SwiftUI Spacer view.
    private func emptyColumn() -> some View {
        column("", "")
    }

    private var caloriesText: String {
        stats.totalCalories > 0
            ? String(format: "%.0f", stats.totalCalories)
            : "—"
    }

    /// Distance is only surfaced when the category actually records it.
    private var distanceText: String? {
        stats.totalDistanceMiles > 0
            ? String(format: "%.1f", stats.totalDistanceMiles)
            : nil
    }

    /// Heart rate is only surfaced when at least one workout supplied it.
    private var heartRateText: String {
        guard let hr = stats.averageHeartRate else { return "—" }
        return String(format: "%.0f", hr)
    }

    private var lastWorkoutText: String {
        guard let date = stats.lastWorkoutDate else { return "—" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    private func column(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.title3)
                .fontWeight(.semibold)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }
}
