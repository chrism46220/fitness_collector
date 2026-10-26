//
//  FitnessOverviewView.swift
//  FitnessCollector
//
//  LEVEL 1 — Fitness overview. The app's initial screen.
//
//  Shows aggregate statistics across all workouts and provides navigable tiles
//  for each activity category. Category views are Level 2.
//

import SwiftUI

struct FitnessOverviewView: View {
    @ObservedObject var health: HealthKitManager

    private var allWorkouts: [WorkoutRow] { health.workouts }

    private var overall: ActivityStatistics {
        ActivityStatistics.make(from: allWorkouts)
    }

    private var recent: [WorkoutRow] {
        allWorkouts
            .sorted { $0.start > $1.start }
            .prefix(5)
            .map { $0 }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    OverviewSummaryCard(stats: overall)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                if allWorkouts.isEmpty {
                    Section {
                        EmptyStatePanel(health: health)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                } else {
                    Section("Activity") {
                        ForEach(ActivityCategory.allCases) { category in
                            NavigationLink {
                                ActivityView(category: category, health: health)
                            } label: {
                                ActivityCategoryRow(
                                    category: category,
                                    stats: ActivityStatistics.make(
                                        from: allWorkouts.inCategory(category)
                                    )
                                )
                            }
                        }
                    }

                    if !recent.isEmpty {
                        Section("Recent Activity") {
                            ForEach(recent) { workout in
                                NavigationLink {
                                    WorkoutDetailView(
                                        workout: workout.hkWorkout,
                                        summary: workout,
                                        health: health
                                    )
                                } label: {
                                    RecentWorkoutRow(workout: workout)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Fitness")
            .refreshable {
                health.requestAccessAndLoadWorkouts()
            }
        }
    }
}

// MARK: - Empty state

/// The Level 1 empty state.
///
/// Shown when no workouts are loaded. It deliberately renders human copy only:
/// `statusMessage` is presentation text and any raw HealthKit error detail lives
/// in `diagnosticMessage`, tucked behind a disclosure for troubleshooting.
private struct EmptyStatePanel: View {
    @ObservedObject var health: HealthKitManager

    private var title: String {
        health.hasRequestedAccess ? "No workouts yet" : "Connect Apple Health"
    }

    private var explainer: String {
        health.hasRequestedAccess
            ? "Fitness reads workouts already recorded by Apple Watch or the Health app. Nothing has been found yet."
            : "Fitness reads the workouts Apple Health already has on this device. Nothing is uploaded or shared."
    }

    private var primaryActionTitle: String {
        health.hasRequestedAccess ? "Reload Workouts" : "Connect to Apple Health"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "heart.text.square")
                    .font(.title2)
                    .foregroundStyle(.tint)

                Text(title)
                    .font(.headline)
            }

            Text(explainer)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(health.statusMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(primaryActionTitle) {
                health.requestAccessAndLoadWorkouts()
            }
            .buttonStyle(.borderedProminent)

            if let diagnostic = health.diagnosticMessage {
                DisclosureGroup("Technical details") {
                    Text(diagnostic)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
                .font(.footnote)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.vertical, 6)
    }
}

// MARK: - Summary card

private struct OverviewSummaryCard: View {
    let stats: ActivityStatistics

    private var durationText: String {
        guard stats.workoutCount > 0 else { return "—" }
        return formatDuration(stats.totalDurationMinutes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("All Activity")
                .font(.headline)

            HStack(alignment: .top, spacing: 0) {
                summaryColumn(
                    value: "\(stats.workoutCount)",
                    label: "Workouts"
                )
                summaryColumn(
                    value: durationText,
                    label: "Total Time"
                )
                summaryColumn(
                    value: stats.totalDistanceMiles > 0
                        ? String(format: "%.1f", stats.totalDistanceMiles)
                        : "—",
                    label: "Miles"
                )
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.vertical, 6)
    }

    private func summaryColumn(value: String, label: String) -> some View {
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

// MARK: - Category row

private struct ActivityCategoryRow: View {
    let category: ActivityCategory
    let stats: ActivityStatistics

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: category.symbolName)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(category.title)
                    .font(.headline)

                if stats.isEmpty {
                    Text("No workouts")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(detailLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var detailLine: String {
        let count = stats.workoutCount
        let workoutWord = count == 1 ? "workout" : "workouts"
        return "\(count) \(workoutWord) · \(formatDuration(stats.totalDurationMinutes))"
    }
}

// MARK: - Recent row

private struct RecentWorkoutRow: View {
    let workout: WorkoutRow

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: workout.category.symbolName)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(workout.type)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(workout.start.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text(formatDuration(workout.durationMinutes))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
