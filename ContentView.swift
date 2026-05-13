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
    let type: String
    let start: Date
    let durationMinutes: Double
    let calories: Double?
    let distanceMiles: Double?
    let averageHeartRate: Double?
    let maxHeartRate: Double?

    var averagePaceSecondsPerMile: Double? {
        guard let distanceMiles, distanceMiles > 0 else { return nil }
        return (durationMinutes * 60.0) / distanceMiles
    }
}

final class HealthKitManager: ObservableObject {
    private let healthStore = HKHealthStore()

    @Published var workouts: [WorkoutRow] = []
    @Published var statusMessage: String = "Not connected"

    @Published var heartRateSamples: [HeartRateSample] = []
    @Published var heartRateDetailMessage: String = ""

    @Published var paceSamples: [PaceSample] = []
    @Published var paceDetailMessage: String = ""

    func requestAccessAndLoadWorkouts() {
        guard HKHealthStore.isHealthDataAvailable() else {
            statusMessage = "Health data not available."
            return
        }

        let readTypes: Set<HKObjectType> = [
            HKObjectType.workoutType(),
            HKQuantityType.quantityType(forIdentifier: .heartRate)!,
            HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)!,
            HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning)!,
            HKSeriesType.workoutRoute()
        ]

        healthStore.requestAuthorization(toShare: [], read: readTypes) { [weak self] success, error in
            DispatchQueue.main.async {
                if let error = error {
                    self?.statusMessage = "Auth error: \(error.localizedDescription)"
                    return
                }

                if success {
                    self?.statusMessage = "Health access granted. Loading workouts..."
                    self?.loadWorkouts()
                } else {
                    self?.statusMessage = "Access denied"
                }
            }
        }
    }

    private func loadWorkouts() {
        statusMessage = "Loading workouts..."

        let query = HKSampleQuery(
            sampleType: .workoutType(),
            predicate: nil,
            limit: 100,
            sortDescriptors: [
                NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
            ]
        ) { [weak self] _, samples, error in

            DispatchQueue.main.async {
                if let error = error {
                    self?.statusMessage = "Workout query error: \(error.localizedDescription)"
                    return
                }

                guard let hkWorkouts = samples as? [HKWorkout] else {
                    self?.statusMessage = "Samples were not workouts"
                    return
                }

                if hkWorkouts.isEmpty {
                    self?.statusMessage = "No workouts returned from HealthKit"
                    return
                }

                let energyType = HKQuantityType(.activeEnergyBurned)

                self?.workouts = hkWorkouts.map { workout in
                    WorkoutRow(
                        id: workout.uuid,
                        hkWorkout: workout,
                        type: workout.workoutActivityType.displayName,
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
                self?.statusMessage = "Loaded \(hkWorkouts.count) workouts, \(runCount) runs"

                self?.fetchHeartRates(for: hkWorkouts)
            }
        }

        healthStore.execute(query)
    }

    private func fetchHeartRates(for hkWorkouts: [HKWorkout]) {
        guard let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate) else {
            statusMessage = "Heart rate type unavailable"
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
                    DispatchQueue.main.async {
                        self?.statusMessage = "HR error: \(error.localizedDescription)"
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
                            type: old.type,
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

    private func smoothPaceSamples(_ samples: [PaceSample]) -> [PaceSample] {
        // GPS-derived instantaneous pace is naturally noisy. A centered rolling
        // average makes the chart readable while preserving real slowdowns/stops.
        guard samples.count >= 15 else { return samples }

        let halfWindow = 8   // about 15–20 seconds for typical Apple Watch route data

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

struct ContentView: View {
    @StateObject private var health = HealthKitManager()
    @State private var chartRange: ChartRange = .thirty
    @State private var selectedWorkout: WorkoutRow?

    private var runs: [WorkoutRow] {
        health.workouts
            .filter { $0.type == "Running" }
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
        NavigationStack {
            VStack(spacing: 16) {

                Text(health.statusMessage)
                    .font(.headline)

                Button("Connect to Apple Health") {
                    health.requestAccessAndLoadWorkouts()
                }
                .buttonStyle(.borderedProminent)

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
                        ForEach(health.workouts) { workout in
                            NavigationLink {
                                WorkoutDetailView(workout: workout.hkWorkout, summary: workout, health: health)
                            } label: {
                                WorkoutRowView(workout: workout)
                            }
                        }
                    }
                }
            }
            .padding()
            .navigationTitle("Fitness Collector")
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

    private let pointSpacing: CGFloat = 58
    private let chartHeight: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)

            GeometryReader { geometry in
                ScrollView(.horizontal, showsIndicators: true) {
                    chartBody(width: chartWidth(containerWidth: geometry.size.width))
                        .frame(
                            width: chartWidth(containerWidth: geometry.size.width),
                            height: chartHeight
                        )
                }
            }
            .frame(height: chartHeight + 12)

            Text("Drag sideways to scroll · Tap a point for details")
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
        let calculated = CGFloat(max(runs.count, 1)) * pointSpacing
        return max(containerWidth, calculated)
    }

    private func closestRun(to date: Date) -> WorkoutRow? {
        runs.min(by: {
            abs($0.start.timeIntervalSince(date)) <
            abs($1.start.timeIntervalSince(date))
        })
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

                        let paces = health.paceSamples.map { $0.paceMinutesPerMile }
                        let filtered = paces.filter { $0 >= 6 && $0 <= 16 }

                        let minPace = (filtered.min() ?? 8) - 0.5
                        let maxPace = (filtered.max() ?? 14) + 0.5

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
                        .chartYScale(domain: minPace...maxPace)
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

private func paceYAxisDomain(_ samples: [PaceSample]) -> ClosedRange<Double> {
    let paces = samples
        .map { $0.paceMinutesPerMile }
        .filter { $0.isFinite }
        .sorted()

    guard !paces.isEmpty else { return 8.0...14.0 }

    // Use percentile trimming so one weird GPS point does not stretch the axis.
    let lowIndex = max(0, Int(Double(paces.count - 1) * 0.05))
    let highIndex = min(paces.count - 1, Int(Double(paces.count - 1) * 0.95))

    let low = max(4.0, paces[lowIndex] - 0.5)
    let high = min(20.0, paces[highIndex] + 0.5)

    if low >= high {
        return max(4.0, low - 1.0)...min(20.0, high + 1.0)
    }

    return low...high
}

private func formatPace(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    let min = total / 60
    let sec = total % 60
    return "\(min):\(String(format: "%02d", sec))"
}

private func formatPaceMinutes(_ minutesPerMile: Double) -> String {
    let totalSeconds = Int((minutesPerMile * 60.0).rounded())
    let min = totalSeconds / 60
    let sec = totalSeconds % 60
    return "\(min):\(String(format: "%02d", sec))"
}

private func formatDistance(_ miles: Double) -> String {
    String(format: "%.2f", miles)
}

private func formatDuration(_ minutes: Double) -> String {
    String(format: "%.1f", minutes)
}

private func formatCalories(_ calories: Double) -> String {
    String(format: "%.0f", calories)
}

private func formatHeartRate(_ bpm: Double) -> String {
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

