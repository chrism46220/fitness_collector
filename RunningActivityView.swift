import SwiftUI
import HealthKit
import Combine
import Charts
import CoreLocation

enum ChartRange: String, CaseIterable {
    case seven = "7D"
    case thirty = "30D"
    case ninety = "90D"
    case all = "All"
}

struct HeartRateSample: Identifiable {
    let id = UUID()
    let date: Date
    let bpm: Double
    let minutesFromStart: Double
}

struct PaceSample: Identifiable {
    let id = UUID()
    let minutesFromStart: Double
    let paceMinutesPerMile: Double
}

struct WorkoutRow: Identifiable {
    let id: UUID
    let hkWorkout: HKWorkout
    /// The raw HealthKit activity type. This is the source of truth.
    let activityType: HKWorkoutActivityType
    let start: Date
    let durationMinutes: Double
    let calories: Double?
    let distanceMiles: Double?
    let averageHeartRate: Double?
    let maxHeartRate: Double?

    /// Display label for the activity type.
    var type: String { activityType.displayName }

    /// The app-level category this workout belongs to.
    var category: ActivityCategory { activityType.category }

    var averagePaceSecondsPerMile: Double? {
        guard let distanceMiles, distanceMiles > 0 else { return nil }
        return (durationMinutes * 60.0) / distanceMiles
    }
}

final class HealthKitManager: ObservableObject {
    private let healthStore = HKHealthStore()

    /// Limit passed to the workout sample query.
    ///
    /// Earlier builds passed a hard-coded 100, which silently capped history at
    /// the most recent 100 workouts and under-reported overview totals and
    /// category counts. `HKObjectQueryNoLimit` returns the complete workout
    /// history. Kept as a named constant rather than an inline literal so the
    /// regression tests can assert the query is unbounded.
    static let workoutQueryLimit = HKObjectQueryNoLimit

    @Published var workouts: [WorkoutRow] = []
    /// Human-facing status copy. This is the only string the UI displays, so it
    /// must never carry raw `NSError`/`localizedDescription` text.
    @Published var statusMessage: String = "Not connected"

    /// Diagnostic detail for the most recent failure, if any. Raw HealthKit
    /// error text belongs here rather than in `statusMessage`; the UI shows it
    /// behind a disclosure so a query failure never masquerades as user guidance.
    @Published var diagnosticMessage: String?

    /// True once authorization has been requested and completed successfully.
    /// Distinguishes "never connected" from "connected but no workouts", which
    /// need different empty-state copy.
    @Published var hasRequestedAccess: Bool = false

    @Published var heartRateSamples: [HeartRateSample] = []
    @Published var heartRateDetailMessage: String = ""

    @Published var paceSamples: [PaceSample] = []
    @Published var paceDetailMessage: String = ""

    /// Turns a raw HealthKit error into copy that is safe to show a person.
    ///
    /// HealthKit surfaces `"No data available for the specified predicate"` for
    /// several underlying conditions (unavailable sample type, unresolved
    /// authorization, or a genuinely empty range), so the raw description is not
    /// meaningful to a user. The underlying description is kept in
    /// `diagnosticMessage` for debugging.
    static func userFacingMessage(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == HKError.errorDomain {
            return "Apple Health could not return this data. Try again, or check Health access in Settings."
        }
        return "Apple Health returned an error. Try again, or check Health access in Settings."
    }

    func requestAccessAndLoadWorkouts() {
        guard HKHealthStore.isHealthDataAvailable() else {
            statusMessage = "Health data is not available on this device."
            diagnosticMessage = nil
            return
        }

        var readTypes: Set<HKObjectType> = [
            HKObjectType.workoutType(),
            HKSeriesType.workoutRoute()
        ]

        // Optional quantity types are added only when the device reports them.
        // Force-unwrapping these identifiers crashes or silently misbehaves on
        // devices/OS versions where a type is unavailable.
        for identifier: HKQuantityTypeIdentifier in [
            .heartRate,
            .activeEnergyBurned,
            .basalEnergyBurned,
            .distanceWalkingRunning,
            .distanceCycling,
            .distanceSwimming,
            .distanceWheelchair,
            .distanceDownhillSnowSports
        ] {
            if let type = HKQuantityType.quantityType(forIdentifier: identifier) {
                readTypes.insert(type)
            }
        }

        diagnosticMessage = nil
        statusMessage = "Requesting Health access..."

        healthStore.requestAuthorization(toShare: [], read: readTypes) { [weak self] success, error in
            DispatchQueue.main.async {
                guard let self = self else { return }

                if let error = error {
                    self.hasRequestedAccess = true
                    self.diagnosticMessage = error.localizedDescription
                    self.statusMessage = "Apple Health access failed. Tap to try again."
                    return
                }

                self.hasRequestedAccess = true

                if success {
                    self.loadWorkouts()
                } else {
                    self.statusMessage = "Health access was not granted."
                }
            }
        }
    }

    private func loadWorkouts() {
        statusMessage = "Loading workouts..."

        let query = HKSampleQuery(
            sampleType: .workoutType(),
            predicate: nil,
            limit: HealthKitManager.workoutQueryLimit,
            sortDescriptors: [
                NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
            ]
        ) { [weak self] _, samples, error in

            DispatchQueue.main.async {
                guard let self = self else { return }

                // A nil sample array is a query failure, not an empty library.
                // Handle it before the type cast so the distinction survives.
                if let error = error {
                    self.diagnosticMessage = error.localizedDescription
                    self.statusMessage = HealthKitManager.userFacingMessage(for: error)
                    self.workouts = []
                    return
                }

                guard let hkWorkouts = samples as? [HKWorkout] else {
                    self.workouts = []
                    self.statusMessage = "Apple Health did not return workout data."
                    self.diagnosticMessage = "HKSampleQuery returned a non-workout sample array."
                    return
                }

                self.diagnosticMessage = nil

                // An empty result is a valid state for a user with no recorded
                // workouts. Clear the published list so stale rows never linger
                // behind an "empty" message, and let the overview render its
                // empty state from the now-empty workout array.
                if hkWorkouts.isEmpty {
                    self.workouts = []
                    self.statusMessage = "No workouts found in Apple Health yet."
                    return
                }

                let energyType = HKQuantityType(.activeEnergyBurned)

                self.workouts = hkWorkouts.map { workout in
                    WorkoutRow(
                        id: workout.uuid,
                        hkWorkout: workout,
                        activityType: workout.workoutActivityType,
                        start: workout.startDate,
                        durationMinutes: workout.duration / 60.0,
                        calories: workout
                            .statistics(for: energyType)?
                            .sumQuantity()?
                            .doubleValue(for: .kilocalorie()),
                        distanceMiles: workout.totalDistance?.doubleValue(for: .mile()),
                        averageHeartRate: nil,
                        maxHeartRate: nil
                    )
                }

                let runCount = hkWorkouts.filter { $0.workoutActivityType == .running }.count
                self.statusMessage = "Loaded \(hkWorkouts.count) workouts (\(runCount) running)."
                self.diagnosticMessage = nil

                self.fetchHeartRates(for: hkWorkouts)
            }
        }

        healthStore.execute(query)
    }

    private func fetchHeartRates(for hkWorkouts: [HKWorkout]) {
        guard let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate) else {
            // Heart-rate enrichment is optional. A missing type must not
            // overwrite the workout list's status copy with an internal error.
            return
        }

        for workout in hkWorkouts {
            let predicate = HKQuery.predicateForSamples(
                withStart: workout.startDate,
                end: workout.endDate,
                options: .strictStartDate
            )

            let query = HKStatisticsQuery(
                quantityType: hrType,
                quantitySamplePredicate: predicate,
                options: [.discreteAverage, .discreteMax]
            ) { [weak self] _, stats, error in

                if let error = error {
                    // Per-workout statistics failures are common for individual
                    // workouts (no HR samples recorded) and are not actionable
                    // for the user. Record the first one for diagnostics only.
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        if self.diagnosticMessage == nil {
                            self.diagnosticMessage = "Heart rate statistics: \(error.localizedDescription)"
                        }
                    }
                    return
                }

                let bpmUnit = HKUnit.count().unitDivided(by: .minute())

                let avgHR = stats?
                    .averageQuantity()?
                    .doubleValue(for: bpmUnit)

                let maxHR = stats?
                    .maximumQuantity()?
                    .doubleValue(for: bpmUnit)

                DispatchQueue.main.async {
                    guard let self = self else { return }

                    if let index = self.workouts.firstIndex(where: { $0.id == workout.uuid }) {
                        let old = self.workouts[index]

                        self.workouts[index] = WorkoutRow(
                            id: old.id,
                            hkWorkout: old.hkWorkout,
                            activityType: old.activityType,
                            start: old.start,
                            durationMinutes: old.durationMinutes,
                            calories: old.calories,
                            distanceMiles: old.distanceMiles,
                            averageHeartRate: avgHR,
                            maxHeartRate: maxHR
                        )
                    }
                }
            }

            healthStore.execute(query)
        }
    }

    func fetchHeartRateSamples(for workout: HKWorkout) {
        guard let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate) else {
            DispatchQueue.main.async {
                self.heartRateDetailMessage = "Heart rate type unavailable"
                self.heartRateSamples = []
            }
            return
        }

        DispatchQueue.main.async {
            self.heartRateSamples = []
            self.heartRateDetailMessage = "Loading heart rate samples..."
        }

        let predicate = HKQuery.predicateForSamples(
            withStart: workout.startDate,
            end: workout.endDate,
            options: .strictStartDate
        )

        let sortDescriptor = NSSortDescriptor(
            key: HKSampleSortIdentifierStartDate,
            ascending: true
        )

        let query = HKSampleQuery(
            sampleType: hrType,
            predicate: predicate,
            limit: HKObjectQueryNoLimit,
            sortDescriptors: [sortDescriptor]
        ) { [weak self] _, samples, error in

            if let error = error {
                DispatchQueue.main.async {
                    self?.heartRateDetailMessage = "HR sample error: \(error.localizedDescription)"
                    self?.heartRateSamples = []
                }
                return
            }

            guard let samples = samples as? [HKQuantitySample] else {
                DispatchQueue.main.async {
                    self?.heartRateDetailMessage = "No HR samples returned"
                    self?.heartRateSamples = []
                }
                return
            }

            let bpmUnit = HKUnit.count().unitDivided(by: .minute())

            let data = samples.map { sample in
                HeartRateSample(
                    date: sample.startDate,
                    bpm: sample.quantity.doubleValue(for: bpmUnit),
                    minutesFromStart: sample.startDate.timeIntervalSince(workout.startDate) / 60.0
                )
            }

            DispatchQueue.main.async {
                self?.heartRateSamples = data
                self?.heartRateDetailMessage = data.isEmpty
                    ? "No HR samples found for this workout"
                    : "Loaded \(data.count) HR samples"
            }
        }

        healthStore.execute(query)
    }

    func fetchPaceSamples(for workout: HKWorkout) {
        DispatchQueue.main.async {
            self.paceSamples = []
            self.paceDetailMessage = "Loading route data..."
        }

        let routeType = HKSeriesType.workoutRoute()
        let predicate = HKQuery.predicateForObjects(from: workout)

        let routeQuery = HKSampleQuery(
            sampleType: routeType,
            predicate: predicate,
            limit: HKObjectQueryNoLimit,
            sortDescriptors: nil
        ) { [weak self] _, samples, error in

            if let error = error {
                DispatchQueue.main.async {
                    self?.paceDetailMessage = "Route error: \(error.localizedDescription)"
                    self?.paceSamples = []
                }
                return
            }

            guard let routes = samples as? [HKWorkoutRoute], !routes.isEmpty else {
                DispatchQueue.main.async {
                    self?.paceDetailMessage = "No route found for this workout"
                    self?.paceSamples = []
                }
                return
            }

            var allLocations: [CLLocation] = []
            let group = DispatchGroup()

            for route in routes {
                group.enter()

                let locationQuery = HKWorkoutRouteQuery(route: route) { _, locations, done, error in
                    if let error = error {
                        DispatchQueue.main.async {
                            self?.paceDetailMessage = "Location error: \(error.localizedDescription)"
                        }
                    }

                    if let locations = locations {
                        allLocations.append(contentsOf: locations)
                    }

                    if done {
                        group.leave()
                    }
                }

                self?.healthStore.execute(locationQuery)
            }

            group.notify(queue: .global(qos: .userInitiated)) {
                let sortedLocations = allLocations.sorted { $0.timestamp < $1.timestamp }

                guard sortedLocations.count > 1 else {
                    DispatchQueue.main.async {
                        self?.paceDetailMessage = "Not enough GPS points for pace"
                        self?.paceSamples = []
                    }
                    return
                }

                var rawSamples: [PaceSample] = []

                for i in 1..<sortedLocations.count {
                    let previous = sortedLocations[i - 1]
                    let current = sortedLocations[i]

                    let distanceMeters = current.distance(from: previous)
                    let seconds = current.timestamp.timeIntervalSince(previous.timestamp)

                    guard seconds > 0 else { continue }
                    guard distanceMeters > 0 else { continue }

                    let speedMetersPerSecond = distanceMeters / seconds
                    guard speedMetersPerSecond > 0 else { continue }

                    let paceMinutesPerMile = (1609.34 / speedMetersPerSecond) / 60.0
                    let minutesFromStart = current.timestamp.timeIntervalSince(workout.startDate) / 60.0

                    // Clean up raw GPS noise:
                    // - ignore the first 30 seconds while GPS/watch start-up settles
                    // - ignore tiny movement segments that behave like standing still
                    // - ignore odd GPS time gaps that create fake pace spikes
                    // - ignore unrealistic running/walking paces
                    guard minutesFromStart >= 0.5 else { continue }
                    guard seconds <= 10.0 else { continue }
                    guard distanceMeters >= 1.5 else { continue }
                    guard speedMetersPerSecond >= 0.75 else { continue }
                    guard paceMinutesPerMile >= 4.0, paceMinutesPerMile <= 20.0 else { continue }

                    rawSamples.append(
                        PaceSample(
                            minutesFromStart: minutesFromStart,
                            paceMinutesPerMile: paceMinutesPerMile
                        )
                    )
                }

                let smoothedSamples = self?.smoothPaceSamples(rawSamples) ?? rawSamples

                DispatchQueue.main.async {
                    self?.paceSamples = smoothedSamples
                    self?.paceDetailMessage = smoothedSamples.isEmpty
                        ? "No pace samples could be calculated"
                        : "Loaded \(smoothedSamples.count) smoothed pace samples"
                }
            }
        }

        healthStore.execute(routeQuery)
    }

    func smoothPaceSamples(_ samples: [PaceSample]) -> [PaceSample] {
        // GPS-derived instantaneous pace is naturally noisy. A centred rolling
        // average makes the chart readable while preserving real slowdowns/stops.
        // Implementation lives in PaceSmoothing so it can be unit tested.
        PaceSmoothing.smooth(samples)
    }
}

struct RunningActivityView: View {
    @ObservedObject var health: HealthKitManager
    @State private var chartRange: ChartRange = .thirty
    @State private var selectedWorkout: WorkoutRow?

    private var runs: [WorkoutRow] {
        health.workouts
            .filter { $0.category == .running }
            .sorted { $0.start < $1.start }
    }

    private var chartRuns: [WorkoutRow] {
        guard chartRange != .all else { return runs }

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

        return runs.filter { $0.start >= cutoff }
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
                    if !runs.isEmpty {
                        Section("Run Trends") {
                            Picker("Range", selection: $chartRange) {
                                ForEach(ChartRange.allCases, id: \.self) { range in
                                    Text(range.rawValue).tag(range)
                                }
                            }
                            .pickerStyle(.segmented)
                            
                            RunMetricChart(
                                title: "Distance per Run",
                                unit: "Miles",
                                runs: chartRuns,
                                chartRange: chartRange,
                                value: { $0.distanceMiles },
                                onSelectWorkout: { selectedWorkout = $0 }
                            )
                            
                            RunMetricChart(
                                title: "Average Heart Rate",
                                unit: "BPM",
                                runs: chartRuns,
                                chartRange: chartRange,
                                value: { $0.averageHeartRate },
                                onSelectWorkout: { selectedWorkout = $0 }
                            )
                            
                            RunMetricChart(
                                title: "Max Heart Rate",
                                unit: "BPM",
                                runs: chartRuns,
                                chartRange: chartRange,
                                value: { $0.maxHeartRate },
                                onSelectWorkout: { selectedWorkout = $0 }
                            )
                        }
                    } else {
                        Section("Run Trends") {
                            Text("No running workouts loaded yet.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    Section("Workouts") {
                        ForEach(runs.reversed()) { workout in
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

struct RunMetricChart: View {
    let title: String
    let unit: String
    let runs: [WorkoutRow]
    let chartRange: ChartRange
    let value: (WorkoutRow) -> Double?
    let onSelectWorkout: (WorkoutRow) -> Void

    @State private var selectedDate: Date?
    @State private var isScrollEnabled: Bool = false

    private let pointSpacing: CGFloat = 58
    private let chartHeight: CGFloat = 220
    private let yAxisWidth: CGFloat = 42
    private let yAxisSpacing: CGFloat = 6
    private let yAxisTickCount = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                    Text(unit.uppercased())
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(Capsule())
                }

                HStack {
                    Spacer()

                    Picker("Scroll", selection: $isScrollEnabled) {
                        Text("Scroll Off").tag(false)
                        Text("Scroll On").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 168)
                }
            }

            GeometryReader { geometry in
                let availablePlotWidth = max(1, geometry.size.width - yAxisWidth - yAxisSpacing)
                let plotWidth = chartWidth(containerWidth: availablePlotWidth)

                HStack(alignment: .top, spacing: yAxisSpacing) {
                    yAxisColumn()

                    if isScrollEnabled {
                        ScrollView(.horizontal, showsIndicators: true) {
                            chartBody(width: plotWidth)
                                .frame(
                                    width: plotWidth,
                                    height: chartHeight
                                )
                        }
                    } else {
                        chartBody(width: availablePlotWidth)
                            .frame(
                                width: availablePlotWidth,
                                height: chartHeight
                            )
                    }
                }
            }
            .frame(height: chartHeight + 20)

            Text(isScrollEnabled ? "Scroll to explore · Tap a run" : "Full range shown · Tap a run")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let selectedDate,
               let closest = closestRun(to: selectedDate) {

                VStack(alignment: .leading) {
                    Text(closest.start.formatted(date: .abbreviated, time: .shortened))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text("Run Time: \(formatDuration(closest.durationMinutes)) min")

                    if let y = value(closest) {
                        Text("\(unit): \(formatValue(y))")
                            .font(.headline)
                    }

                    if let pace = closest.averagePaceSecondsPerMile {
                        Text("Pace: \(formatPace(pace))/mi")
                    }

                    if let hr = closest.averageHeartRate {
                        Text("Avg HR: \(formatHeartRate(hr)) bpm")
                    }

                    if let maxHR = closest.maxHeartRate {
                        Text("Max HR: \(formatHeartRate(maxHR)) bpm")
                    }
                }
                .padding(.top, 6)
            }
        }
        .padding(.vertical, 8)
    }

    private func yAxisColumn() -> some View {
        let ticks = yAxisTickValues().reversed()

        return VStack(spacing: 0) {
            ForEach(Array(ticks.enumerated()), id: \.element) { index, tick in
                Text(formatAxisTick(tick))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)

                if index < yAxisTickCount - 1 {
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(width: yAxisWidth, height: chartHeight)
        // These roughly match Swift Charts' internal plot-area inset so the
        // fixed labels line up with the visible horizontal gridlines.
        .padding(.top, 8)
        .padding(.bottom, 30)
    }

    func yDomain() -> ClosedRange<Double> {
        // Implementation lives in ChartGeometry so it can be unit tested.
        ChartGeometry.yDomain(runs, value: value)
    }

    func yAxisTickValues(tickCount: Int? = nil) -> [Double] {
        // Implementation lives in ChartGeometry so it can be unit tested.
        ChartGeometry.tickValues(in: yDomain(), tickCount: tickCount ?? self.yAxisTickCount)
    }

    private func formatAxisTick(_ value: Double) -> String {
        if unit.lowercased().contains("bpm") {
            return String(format: "%.0f", value)
        }

        if unit.lowercased().contains("mile") {
            return String(format: "%.1f", value)
        }

        return String(format: "%.0f", value)
    }

    private func chartBody(width: CGFloat) -> some View {
        Chart {
            ForEach(runs) { run in
                if let y = value(run) {
                    LineMark(
                        x: .value("Date", run.start),
                        y: .value(unit, y)
                    )
                    .interpolationMethod(.catmullRom)

                    PointMark(
                        x: .value("Date", run.start),
                        y: .value(unit, y)
                    )
                }
            }

            if let selectedDate,
               let selected = closestRun(to: selectedDate),
               let y = value(selected) {
                PointMark(
                    x: .value("Selected Date", selected.start),
                    y: .value(unit, y)
                )
                .symbolSize(120)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        SpatialTapGesture()
                            .onEnded { tap in
                                guard let plotFrame = proxy.plotFrame else { return }

                                let x = tap.location.x - geo[plotFrame].origin.x

                                if let date: Date = proxy.value(atX: x),
                                   let closest = closestRun(to: date) {
                                    let generator = UIImpactFeedbackGenerator(style: .light)
                                    generator.prepare()
                                    generator.impactOccurred()

                                    selectedDate = closest.start
                                    onSelectWorkout(closest)
                                }
                            }
                    )
            }
        }
        .chartYScale(domain: yDomain())
        .chartYAxis {
            AxisMarks(position: .leading, values: yAxisTickValues()) { _ in
                AxisGridLine()
            }
        }
        .chartXAxis {
            if chartRange == .all {
                AxisMarks(values: .stride(by: .month, count: 1)) { value in
                    AxisGridLine()
                    AxisTick()

                    if let date = value.as(Date.self) {
                        let month = Calendar.current.component(.month, from: date)

                        AxisValueLabel {
                            VStack(spacing: 2) {
                                Text(date.formatted(.dateTime.month(.abbreviated)))

                                if month == 1 {
                                    Text(date.formatted(.dateTime.year()))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            } else {
                AxisMarks()
            }
        }
    }

    private func chartWidth(containerWidth: CGFloat) -> CGFloat {
        guard isScrollEnabled else { return containerWidth }

        let calculated = CGFloat(max(runs.count, 1)) * pointSpacing
        return max(containerWidth, calculated)
    }

    func closestRun(to date: Date) -> WorkoutRow? {
        // Implementation lives in ChartGeometry so it can be unit tested.
        ChartGeometry.closestItem(to: date, in: runs, timestamp: \.start)
    }

    private func formatValue(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

struct WorkoutRowView: View {
    let workout: WorkoutRow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {

            Text(workout.type)
                .font(.headline)

            Text(workout.start.formatted(date: .abbreviated, time: .shortened))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("Duration: \(formatDuration(workout.durationMinutes)) min")

            if let distance = workout.distanceMiles {
                Text("Distance: \(formatDistance(distance)) mi")
            }

            if let pace = workout.averagePaceSecondsPerMile {
                Text("Avg Pace: \(formatPace(pace))/mi")
            }

            if let hr = workout.averageHeartRate {
                Text("Avg HR: \(formatHeartRate(hr)) bpm")
            } else {
                Text("Avg HR: —")
                    .foregroundStyle(.secondary)
            }

            if let maxHR = workout.maxHeartRate {
                Text("Max HR: \(formatHeartRate(maxHR)) bpm")
            }

            if let calories = workout.calories {
                Text("Calories: \(formatCalories(calories)) kcal")
            }
        }
        .padding(.vertical, 4)
    }
}

struct WorkoutDetailView: View {
    let workout: HKWorkout
    let summary: WorkoutRow
    @ObservedObject var health: HealthKitManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {

                Text(summary.type)
                    .font(.largeTitle)
                    .bold()

                Text(workout.startDate.formatted(date: .complete, time: .shortened))
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Divider()

                metricRow(title: "Duration", value: "\(formatDuration(workout.duration / 60.0)) min")

                if let distance = workout.totalDistance?.doubleValue(for: .mile()) ?? summary.distanceMiles {
                    metricRow(title: "Distance", value: "\(formatDistance(distance)) mi")
                }

                if let pace = summary.averagePaceSecondsPerMile {
                    metricRow(title: "Average Pace", value: "\(formatPace(pace))/mi")
                }

                if let hr = summary.averageHeartRate {
                    metricRow(title: "Average Heart Rate", value: "\(formatHeartRate(hr)) bpm")
                } else {
                    metricRow(title: "Average Heart Rate", value: "—")
                }

                if let maxHR = summary.maxHeartRate {
                    metricRow(title: "Max Heart Rate", value: "\(formatHeartRate(maxHR)) bpm")
                }

                if let calories = summary.calories {
                    metricRow(title: "Calories", value: "\(formatCalories(calories)) kcal")
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Heart Rate Over Time")
                        .font(.title2)
                        .bold()

                    Text(health.heartRateDetailMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if !health.heartRateSamples.isEmpty {
                        Chart(health.heartRateSamples) { sample in
                            LineMark(
                                x: .value("Minutes", sample.minutesFromStart),
                                y: .value("BPM", sample.bpm)
                            )
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(.red)
                        }
                        .frame(height: 260)
                        .chartXAxisLabel("Minutes")
                        .chartYAxisLabel("BPM")
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Pace Over Time")
                        .font(.title2)
                        .bold()

                    Text(health.paceDetailMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if !health.paceSamples.isEmpty {

                        Chart(health.paceSamples) { sample in
                            LineMark(
                                x: .value("Minutes", sample.minutesFromStart),
                                y: .value("Pace", sample.paceMinutesPerMile)
                            )
                            .interpolationMethod(.catmullRom)
                        }
                        .frame(height: 260)
                        .chartXAxisLabel("Minutes")
                        .chartYAxisLabel("Pace (min/mi)")
                        .chartYScale(domain: paceYAxisDomain(health.paceSamples))
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Heart Rate + Pace Overlay")
                        .font(.title2)
                        .bold()

                    Text("Pace is inverted and scaled so faster pace trends upward.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if !health.heartRateSamples.isEmpty && !health.paceSamples.isEmpty {
                        Chart {
                            ForEach(health.heartRateSamples) { sample in
                                LineMark(
                                    x: .value("Minutes", sample.minutesFromStart),
                                    y: .value("Value", sample.bpm)
                                )
                                .interpolationMethod(.catmullRom)
                                .foregroundStyle(by: .value("Series", "Heart Rate"))
                            }

                            ForEach(health.paceSamples) { sample in
                                LineMark(
                                    x: .value("Minutes", sample.minutesFromStart),
                                    y: .value("Value", (20.0 - sample.paceMinutesPerMile) * 10.0)
                                )
                                .interpolationMethod(.catmullRom)
                                .foregroundStyle(by: .value("Series", "Pace"))
                            }
                        }
                        .chartForegroundStyleScale([
                            "Heart Rate": .red,
                            "Pace": .blue
                        ])
                        .chartLegend(position: .top, alignment: .leading)
                        .frame(height: 300)
                        .chartXAxisLabel("Minutes")
                        .chartYAxisLabel("HR / scaled pace")
                    } else {
                        Text("Overlay needs both heart rate and pace data.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Workout Detail")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            health.fetchHeartRateSamples(for: workout)
            health.fetchPaceSamples(for: workout)
        }
    }

    private func metricRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .bold()
        }
        .font(.title3)
    }
}

func paceYAxisDomain(_ samples: [PaceSample]) -> ClosedRange<Double> {
    let paces = samples.map { $0.paceMinutesPerMile }
    guard let min = paces.min(),
          let max = paces.max() else {
        return 8...16
    }

    // Add padding
    let padding: Double = 0.8   // 👈 tweak this (0.5–1.5 is sweet spot)

    return (min - padding)...(max + padding)
}

func formatPace(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    let min = total / 60
    let sec = total % 60
    return "\(min):\(String(format: "%02d", sec))"
}

func formatPaceMinutes(_ minutesPerMile: Double) -> String {
    let totalSeconds = Int((minutesPerMile * 60.0).rounded())
    let min = totalSeconds / 60
    let sec = totalSeconds % 60
    return "\(min):\(String(format: "%02d", sec))"
}

func formatDistance(_ miles: Double) -> String {
    String(format: "%.2f", miles)
}

func formatDuration(_ minutes: Double) -> String {
    String(format: "%.1f", minutes)
}

func formatCalories(_ calories: Double) -> String {
    String(format: "%.0f", calories)
}

func formatHeartRate(_ bpm: Double) -> String {
    String(format: "%.0f", bpm)
}

extension HKWorkoutActivityType {
    var displayName: String {
        switch self {
        case .running: return "Running"
        case .walking: return "Walking"
        case .cycling: return "Cycling"
        case .traditionalStrengthTraining: return "Strength Training"
        case .soccer: return "Soccer"
        case .tennis: return "Tennis"
        case .highIntensityIntervalTraining: return "HIIT"
        case .other: return "Other"
        default: return "Workout"
        }
    }
}



