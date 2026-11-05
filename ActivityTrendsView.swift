import SwiftUI

enum ChartRange: String, CaseIterable {
    case seven = "7D"
    case thirty = "30D"
    case ninety = "90D"
    case all = "All"

    func filter(_ workouts: [WorkoutRow], now: Date = Date(), calendar: Calendar = .current) -> [WorkoutRow] {
        let days: Int
        switch self {
        case .seven: days = 7
        case .thirty: days = 30
        case .ninety: days = 90
        case .all: return workouts
        }
        let cutoff = calendar.date(byAdding: .day, value: -days, to: now) ?? now
        return workouts.filter { $0.start >= cutoff }
    }

    /// Calendar-aligned dates for an empty preset, without inventing workout data.
    func emptyDateBounds(now: Date, calendar: Calendar = .current) -> ClosedRange<Date> {
        let days: Int
        switch self {
        case .seven: days = 7
        case .thirty: days = 30
        case .ninety: days = 90
        case .all: days = 365
        }
        let start = calendar.date(byAdding: .day, value: -days, to: now)
            ?? now.addingTimeInterval(-Double(days) * ChartViewport.day)
        return start...now
    }
}

/// Describes a per-workout series without coupling charts to an activity category.
struct WorkoutMetric: Identifiable {
    let id: String
    let title: String
    let unit: String
    let value: (WorkoutRow) -> Double?
    var emptyMessage: String? = nil

    func plottableWorkouts(in workouts: [WorkoutRow]) -> [WorkoutRow] {
        workouts.filter { value($0)?.isFinite == true }
    }
}

struct ActivityTrendsView<SelectionSummary: View>: View {
    @ObservedObject var health: HealthKitManager
    let category: ActivityCategory
    let trendsTitle: String
    let emptyMessage: String
    let workoutNoun: String
    let metrics: [WorkoutMetric]
    var showsMissingDataStates = false
    var showsEmptyRangeCharts = false
    var emptyRangeMessage = "No workouts in this range."
    @ViewBuilder let selectionSummary: (WorkoutRow, String, Double?) -> SelectionSummary
    @State private var chartRange: ChartRange = .thirty
    @State private var selectedWorkout: WorkoutRow?
    @State private var viewport: ChartViewportState?
    // Keep all empty panels stable across body updates and gestures.
    @State private var emptyRangeReferenceDate = Date()

    private var workouts: [WorkoutRow] {
        health.workouts
            .filter { $0.category == category }
            .sorted { $0.start < $1.start }
    }

    private var chartWorkouts: [WorkoutRow] {
        chartRange.filter(workouts)
    }

    private var viewportContext: ChartViewportContext {
        ChartViewportContext(category: category.rawValue, preset: chartRange.rawValue,
                             extent: showsEmptyRangeCharts && chartWorkouts.isEmpty
                                ? chartRange.emptyDateBounds(now: emptyRangeReferenceDate)
                                : ChartViewport.bounds(for: chartWorkouts.map(\.start)),
                             activityDates: Array(Set(chartWorkouts.map(\.start))).sorted())
    }

    private var currentViewport: ChartViewportState {
        var state = viewport ?? ChartViewportState(context: viewportContext)
        state.reconcile(viewportContext)
        return state
    }

    private var visibleDateRange: Binding<ClosedRange<Date>> {
        Binding(get: { currentViewport.visible }, set: { range in
            var state = currentViewport
            state.visible = ChartViewport.clamp(range, to: viewportContext.extent)
            viewport = state
        })
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

                        if showsEmptyRangeCharts && chartWorkouts.isEmpty {
                            ForEach(metrics) { metric in
                                WorkoutMetricChart(
                                    title: metric.title,
                                    unit: metric.unit,
                                    workouts: [],
                                    chartRange: chartRange,
                                    value: metric.value,
                                    onSelectWorkout: { selectedWorkout = $0 },
                                    workoutNoun: workoutNoun,
                                    fullDateRange: viewportContext.extent,
                                    visibleDateRange: visibleDateRange,
                                    interactionID: "\(category.rawValue)-\(chartRange.rawValue)",
                                    emptyMessage: emptyRangeMessage,
                                    selectionSummary: selectionSummary
                                )
                            }
                        } else if showsMissingDataStates && chartWorkouts.isEmpty {
                            Text(emptyRangeMessage)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(metrics) { metric in
                                let metricWorkouts = showsMissingDataStates
                                    ? metric.plottableWorkouts(in: chartWorkouts)
                                    : chartWorkouts

                                if showsMissingDataStates && metricWorkouts.isEmpty {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(metric.title).font(.headline)
                                        Text("No \(metric.title.lowercased()) data in this range.")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.vertical, 8)
                                } else {
                                    WorkoutMetricChart(
                                        title: metric.title,
                                        unit: metric.unit,
                                        workouts: metricWorkouts,
                                        chartRange: chartRange,
                                        value: metric.value,
                                        onSelectWorkout: { selectedWorkout = $0 },
                                        workoutNoun: workoutNoun,
                                        fullDateRange: viewportContext.extent,
                                        visibleDateRange: visibleDateRange,
                                        interactionID: "\(category.rawValue)-\(chartRange.rawValue)",
                                        emptyMessage: metric.emptyMessage,
                                        selectionSummary: selectionSummary
                                    )
                                }
                            }
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
        .onChange(of: viewportContext, initial: true) { _, next in
            var state = viewport ?? ChartViewportState(context: next)
            state.reconcile(next)
            viewport = state
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
