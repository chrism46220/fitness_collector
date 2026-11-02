import XCTest
import HealthKit
@testable import FitnessCollector

final class OtherTrendsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func row(daysAgo: Int = 0,
                     type: HKWorkoutActivityType = .other,
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

    // MARK: - Verify metric definitions
    func testOtherMetricsContainFourUniqueIdsAndValues() {
        let values = OtherActivityView.metrics.map { $0.value(row(calories: 250, heartRate: 110, maxHeartRate: 140)) }
        XCTAssertEqual(values, [45, 250, 110, 140])
        XCTAssertEqual(Set(OtherActivityView.metrics.map(\.id)).count, 4)
    }

    // MARK: - Missing optional measurements stay nil
    func testMissingMeasurementsRemainNil() {
        let w = row()
        let values = OtherActivityView.metrics.map { $0.value(w) }
        XCTAssertEqual(values, [45, nil, nil, nil])
        XCTAssertTrue(OtherActivityView.metrics[1].plottableWorkouts(in: [w]).isEmpty) // calories metric
    }

    // MARK: - Non-finite values are filtered out
    func testNonFiniteHeartRateIsExcluded() {
        let finite = row(heartRate: 100)
        let nonFinite = row(heartRate: .nan)
        let metric = OtherActivityView.metrics[2] // averageHeartRate
        let plotted = metric.plottableWorkouts(in: [finite, nonFinite])
        XCTAssertEqual(plotted.map(\.id), [finite.id])
    }

    // MARK: - Selection works only on plotted workouts
    func testSelectionUsesOnlyPlottedWorkouts() {
        let measured = row(daysAgo: 2, heartRate: 105)
        let missing = row()
        let invalid = row(heartRate: .nan)
        let outside = row(daysAgo: 45, heartRate: 130)
        let metric = OtherActivityView.metrics[2]
        let plotted = metric.plottableWorkouts(in: [measured, missing, invalid, outside])
        let chart = WorkoutMetricChart(
            title: metric.title,
            unit: metric.unit,
            workouts: plotted,
            chartRange: .thirty,
            value: metric.value,
            onSelectWorkout: { _ in },
            workoutNoun: "session",
            activityDates: plotted.map(\.start),
            fullDateRange: ChartViewport.bounds(for: plotted.map(\.start)),
            visibleDateRange: .constant(now.addingTimeInterval(-7 * 86_400)...now),
            isScrollEnabled: .constant(false),
            selectionSummary: { w, u, v in LiftingSelectionSummary(workout: w, unit: u, value: v) }
        )
        XCTAssertEqual(plotted.map(\.id), [measured.id, outside.id])
        XCTAssertEqual(chart.closestWorkout(to: missing.start)?.id, measured.id)
        XCTAssertEqual(chart.closestWorkout(to: outside.start)?.id, measured.id)
    }

    // MARK: - Category isolation (generic "Other" activities)
    func testOtherCategoryIncludesOnlyDesignatedTypes() {
        let otherTypes: [HKWorkoutActivityType] = [.walking, .cycling, .swimming, .yoga]
        let otherWorkouts = otherTypes.map { row(type: $0) }
        let outsiderWorkouts = [row(type: .running), row(type: .tennis), row(type: .traditionalStrengthTraining)]
        let all = otherWorkouts + outsiderWorkouts
        let filtered = all.inCategory(.other)
        XCTAssertEqual(Set(filtered.map(\.activityType)), Set(otherTypes))
    }

    // MARK: - Range filtering behavior
    func testRangeFiltersIncludeBoundaryAndAllHistory() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let workouts = [
            row(daysAgo: 0),
            row(daysAgo: 7),
            row(daysAgo: 8),
            row(daysAgo: 30),
            row(daysAgo: 31),
            row(daysAgo: 90),
            row(daysAgo: 91)
        ]
        XCTAssertEqual(ChartRange.seven.filter(workouts, now: now, calendar: calendar).count, 2)
        XCTAssertEqual(ChartRange.thirty.filter(workouts, now: now, calendar: calendar).count, 4)
        XCTAssertEqual(ChartRange.ninety.filter(workouts, now: now, calendar: calendar).count, 6)
        XCTAssertEqual(ChartRange.all.filter(workouts, now: now, calendar: calendar).count, 7)
    }

    func testIndependentHeartRateColumnsAndInvalidCalories() {
        let averageOnly = row(heartRate: 112)
        let maximumOnly = row(maxHeartRate: 154)
        XCTAssertEqual(OtherActivityView.metrics[2].value(averageOnly), 112)
        XCTAssertNil(OtherActivityView.metrics[3].value(averageOnly))
        XCTAssertNil(OtherActivityView.metrics[2].value(maximumOnly))
        XCTAssertEqual(OtherActivityView.metrics[3].value(maximumOnly), 154)
        let invalidCalories = [row(calories: .nan), row(calories: .infinity)]
        XCTAssertTrue(OtherActivityView.metrics[1].plottableWorkouts(in: invalidCalories).isEmpty)
    }
}
