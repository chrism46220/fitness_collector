import XCTest
import HealthKit
@testable import FitnessCollector

final class TennisTrendsTests: XCTestCase {
    // Fixed reference date for deterministic range calculations
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // Helper to create a WorkoutRow for a given activity type and optional measurements
    private func row(daysAgo: Int = 0,
                     type: HKWorkoutActivityType = .tennis,
                     calories: Double? = nil,
                     heartRate: Double? = nil,
                     maxHeartRate: Double? = nil) -> WorkoutRow {
        let start = now.addingTimeInterval(-Double(daysAgo) * 86_400)
        let workout = HKWorkout(activityType: type, start: start, end: start.addingTimeInterval(2_700))
        return WorkoutRow(id: workout.uuid,
                          hkWorkout: workout,
                          activityType: type,
                          start: start,
                          durationMinutes: 45,
                          calories: calories,
                          distanceMiles: nil,
                          averageHeartRate: heartRate,
                          maxHeartRate: maxHeartRate)
    }

    // MARK: - Metric definitions
    func testTennisMetricsContainFourUniqueIdsAndValues() {
        let metricValues = TennisActivityView.metrics.map { $0.value(row(calories: 250, heartRate: 110, maxHeartRate: 140)) }
        // Expected order matches the static definition in TennisActivityView
        XCTAssertEqual(metricValues, [45, 250, 110, 140])
        XCTAssertEqual(Set(TennisActivityView.metrics.map(\.id)).count, 4)
    }

    // MARK: - Missing optional measurements are not replaced with zero
    func testMissingMeasurementsRemainNil() {
        let w = row()
        let values = TennisActivityView.metrics.map { $0.value(w) }
        XCTAssertEqual(values, [45, nil, nil, nil])
        // The calories metric should have no plottable workouts when calories are nil
        XCTAssertTrue(TennisActivityView.metrics[1].plottableWorkouts(in: [w]).isEmpty)
    }

    // MARK: - Non-finite measurements are excluded from plotting
    func testNonFiniteHeartRateIsFilteredOut() {
        let finite = row(heartRate: 120)
        let nonFinite = row(heartRate: .nan)
        let metric = TennisActivityView.metrics[2] // averageHeartRate metric
        let plotted = metric.plottableWorkouts(in: [finite, nonFinite])
        XCTAssertEqual(plotted.map(\.id), [finite.id])
    }

    // MARK: - Selection works only on plotted sessions
    func testSelectionUsesOnlyPlottedWorkouts() {
        let measured = row(daysAgo: 1, heartRate: 115)
        let missing = row()
        let invalid = row(heartRate: .nan)
        let outside = row(daysAgo: 45, heartRate: 130)
        let metric = TennisActivityView.metrics[2] // averageHeartRate
        let plotted = metric.plottableWorkouts(in: [measured, missing, invalid, outside])
        let chart = WorkoutMetricChart(
            title: metric.title,
            unit: metric.unit,
            workouts: plotted,
            chartRange: .thirty,
            value: metric.value,
            onSelectWorkout: { _ in },
            workoutNoun: "session",
            fullDateRange: ChartViewport.bounds(for: plotted.map(\.start)),
            visibleDateRange: .constant(now.addingTimeInterval(-7 * 86_400)...now),
            selectionSummary: { w, u, v in LiftingSelectionSummary(workout: w, unit: u, value: v) }
        )
        XCTAssertEqual(plotted.map(\.id), [measured.id, outside.id])
        XCTAssertEqual(chart.closestWorkout(to: missing.start)?.id, measured.id)
        XCTAssertEqual(chart.closestWorkout(to: outside.start)?.id, measured.id)
    }

    // MARK: - Category isolation (racquet sports)
    func testTennisCategoryIncludesOnlyRacquetTypes() {
        let racquetTypes: [HKWorkoutActivityType] = [
            .tennis,
            .tableTennis,
            .badminton,
            .pickleball,
            .squash,
            .racquetball
        ]
        let racquetWorkouts = racquetTypes.map { row(type: $0) }
        let outsiderWorkouts = [row(type: .running), row(type: .walking), row(type: .traditionalStrengthTraining)]
        let all = racquetWorkouts + outsiderWorkouts
        let filtered = all.inCategory(.tennis)
        XCTAssertEqual(Set(filtered.map(\.activityType)), Set(racquetTypes))
    }

    // MARK: - Range filtering includes boundaries and all history
    func testRangeFiltersIncludeBoundaryAndAllHistory() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let workouts = [
            row(daysAgo: 0),   // today
            row(daysAgo: 7),   // exactly 7 days ago
            row(daysAgo: 8),
            row(daysAgo: 30), // exactly 30 days ago
            row(daysAgo: 31),
            row(daysAgo: 90), // exactly 90 days ago
            row(daysAgo: 91)
        ]
        XCTAssertEqual(ChartRange.seven.filter(workouts, now: now, calendar: calendar).count, 2) // today + 7d
        XCTAssertEqual(ChartRange.thirty.filter(workouts, now: now, calendar: calendar).count, 4) // today,7d,30d,8d
        XCTAssertEqual(ChartRange.ninety.filter(workouts, now: now, calendar: calendar).count, 6) // all but 91d
        XCTAssertEqual(ChartRange.all.filter(workouts, now: now, calendar: calendar).count, 7)
    }

    func testIndependentHeartRateColumnsAndInvalidCalories() {
        let averageOnly = row(heartRate: 112)
        let maximumOnly = row(maxHeartRate: 154)
        XCTAssertEqual(TennisActivityView.metrics[2].value(averageOnly), 112)
        XCTAssertNil(TennisActivityView.metrics[3].value(averageOnly))
        XCTAssertNil(TennisActivityView.metrics[2].value(maximumOnly))
        XCTAssertEqual(TennisActivityView.metrics[3].value(maximumOnly), 154)
        let invalidCalories = [row(calories: .nan), row(calories: .infinity)]
        XCTAssertTrue(TennisActivityView.metrics[1].plottableWorkouts(in: invalidCalories).isEmpty)
    }
}
