import SwiftUI
import HealthKit
import Combine
import Charts
import CoreLocation

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

    /// Maps a query failure to copy that is safe to display for a missing-data case.
    ///
    /// HealthKit reports `HKError.noData` ("No data available for the specified
    /// predicate") whenever a predicate simply matches nothing - a run recorded
    /// without a watch, a workout with no GPS route. That is an ordinary empty
    /// result, not a fault, and must never be surfaced as raw error text. Any
    /// other failure keeps a generic, actionable message. The underlying
    /// description is kept in `diagnosticMessage` for debugging.
    static func emptyStateMessage(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == HKError.errorDomain,
           nsError.code == HKError.Code.errorNoData.rawValue {
            return "No data recorded for this workout"
        }
        return "Apple Health could not return this data. Try again, or check Health access in Settings."
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
                    self?.heartRateSamples = []
                    self?.heartRateDetailMessage = HealthKitManager.emptyStateMessage(for: error)
                    self?.diagnosticMessage = self?.diagnosticMessage
                        ?? "Heart rate samples: \(error.localizedDescription)"
                }
                return
            }

            guard let samples = samples as? [HKQuantitySample] else {
                DispatchQueue.main.async {
                    self?.heartRateDetailMessage = "No heart rate data for this workout"
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
                    self?.paceSamples = []
                    self?.paceDetailMessage = HealthKitManager.emptyStateMessage(for: error)
                    self?.diagnosticMessage = self?.diagnosticMessage
                        ?? "Workout route: \(error.localizedDescription)"
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
                            self?.diagnosticMessage = self?.diagnosticMessage
                                ?? "Route locations: \(error.localizedDescription)"
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

    var body: some View {
        ActivityTrendsView(
            health: health,
            category: .running,
            trendsTitle: "Run Trends",
            emptyMessage: "No running workouts loaded yet.",
            workoutNoun: "run",
            metrics: [
                WorkoutMetric(id: "distance", title: "Distance per Run", unit: "Miles", value: { $0.distanceMiles }),
                WorkoutMetric(id: "averageHeartRate", title: "Average Heart Rate", unit: "BPM", value: { $0.averageHeartRate }),
                WorkoutMetric(id: "maxHeartRate", title: "Max Heart Rate", unit: "BPM", value: { $0.maxHeartRate })
            ],
            selectionSummary: { workout, unit, value in
                RunningSelectionSummary(workout: workout, unit: unit, value: value)
            }
        )
    }
}

struct RunningSelectionSummary: View {
    let workout: WorkoutRow
    let unit: String
    let value: Double?

    var body: some View {
        VStack(alignment: .leading) {
            Text(workout.start.formatted(date: .abbreviated, time: .shortened))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("Run Time: \(formatDuration(workout.durationMinutes)) min")

            if let value {
                Text("\(unit): \(String(format: "%.2f", value))")
                    .font(.headline)
            }

            if let pace = workout.averagePaceSecondsPerMile {
                Text("Pace: \(formatPace(pace))/mi")
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



