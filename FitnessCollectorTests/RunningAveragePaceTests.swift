import XCTest
import HealthKit
import SwiftUI
@testable import FitnessCollector

final class RunningAveragePaceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var pace: WorkoutMetric { RunningActivityView.metrics.first { $0.id == "averagePace" }! }
    private func row(minutes: Double = 30, miles: Double? = 3, daysAgo: Double = 0, type: HKWorkoutActivityType = .running) -> WorkoutRow {
        let start = now.addingTimeInterval(-daysAgo * 86400)
        let workout = HKWorkout(activityType: type, start: start, end: start.addingTimeInterval(1800))
        return WorkoutRow(id: workout.uuid, hkWorkout: workout, activityType: type, start: start,
                          durationMinutes: minutes, calories: nil, distanceMiles: miles,
                          averageHeartRate: nil, maxHeartRate: nil)
    }
    private func chart(rows: [WorkoutRow], unit: String = "min/mi") -> WorkoutMetricChart<RunningSelectionSummary> {
        let bounds = ChartViewport.bounds(for: rows.map(\.start))
        return WorkoutMetricChart(title: "Average Pace", unit: unit, workouts: rows, chartRange: .all,
            value: pace.value, onSelectWorkout: { _ in }, workoutNoun: "run", activityDates: rows.map(\.start),
            fullDateRange: bounds, visibleDateRange: .constant(bounds), isScrollEnabled: .constant(false),
            emptyMessage: pace.emptyMessage,
            selectionSummary: { RunningSelectionSummary(workout: $0, unit: $1, value: $2) })
    }
    func testPaceIsAddedOnlyToRunningInExpectedOrder() {
        XCTAssertEqual(RunningActivityView.metrics.map(\.id), ["distance", "averagePace", "averageHeartRate", "maxHeartRate"])
        for metrics in [LiftingActivityView.metrics, TennisActivityView.metrics, OtherActivityView.metrics] {
            XCTAssertEqual(metrics.count, 4)
            XCTAssertFalse(metrics.contains { $0.id == "averagePace" })
        }
        XCTAssertEqual(pace.title, "Average Pace")
        XCTAssertEqual(pace.unit, "min/mi")
    }
    func testPerWorkoutTimeDividedByDistanceNotAnAverageAcrossRuns() {
        let workouts = [row(minutes: 20, miles: 2), row(minutes: 60, miles: 10), row(minutes: 45, miles: 6)]
        XCTAssertEqual(workouts.compactMap(pace.value), [600, 360, 450])
    }
    func testFractionalDistanceAndTimeUseSecondsPerMile() {
        XCTAssertEqual(pace.value(row(minutes: 32.5, miles: 5)) ?? -1, 390, accuracy: 1e-9)
        XCTAssertEqual(pace.value(row(minutes: 31, miles: 6.2)) ?? -1, 300, accuracy: 1e-9)
        XCTAssertEqual(chart(rows: []).formatAxisTick(390), "6:30")
    }
    func testInvalidOrMissingDistanceDoesNotCreatePacePoints() {
        for miles: Double? in [nil, 0, -2, .nan, .infinity, -.infinity] {
            XCTAssertNil(pace.value(row(miles: miles)))
        }
    }
    func testInvalidRunningTimeDoesNotCreatePacePoints() {
        for minutes in [0.0, -1, Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertNil(pace.value(row(minutes: minutes)))
        }
    }
    func testNonRunningRowsCannotBecomePaceChartPoints() {
        for type: HKWorkoutActivityType in [.tennis, .walking, .traditionalStrengthTraining] {
            XCTAssertNil(pace.value(row(type: type)))
        }
    }
    func testAxisTimeFormattingRoundsSecondsAndNeverUsesDecimalMinutes() {
        let c = chart(rows: [])
        XCTAssertEqual(c.formatAxisTick(0), "0:00")
        XCTAssertEqual(c.formatAxisTick(450), "7:30")
        XCTAssertEqual(c.formatAxisTick(599.6), "10:00")
        for invalid in [Double.nan, .infinity, -.infinity, -1, Double(Int.max)] {
            XCTAssertEqual(c.formatAxisTick(invalid), "—")
        }
    }
    func testExistingAxisFormatsRemainUnchanged() {
        XCTAssertEqual(chart(rows: [], unit: "BPM").formatAxisTick(151.4), "151")
        XCTAssertEqual(chart(rows: [], unit: "Miles").formatAxisTick(3.12), "3.1")
        XCTAssertEqual(chart(rows: [], unit: "Minutes").formatAxisTick(32.5), "32.5")
        XCTAssertEqual(chart(rows: [], unit: "kcal").formatAxisTick(240.4), "240")
    }
    func testMissingPaceIsExcludedFromPlotAndTapSelection() {
        let valid = row(daysAgo: 1)
        let missing = row(miles: nil)
        let rows = [valid, missing]
        XCTAssertEqual(pace.plottableWorkouts(in: rows).map(\.id), [valid.id])
        XCTAssertEqual(chart(rows: rows).closestWorkout(to: missing.start)?.id, valid.id)
        XCTAssertNil(chart(rows: [missing]).closestWorkout(to: missing.start))
        XCTAssertEqual(pace.emptyMessage, "No average pace data in this range.")
    }
    func testPresetsKeepPerWorkoutPaceAndAllRetainsHistory() {
        let rows = [row(daysAgo: 1), row(daysAgo: 15), row(daysAgo: 60), row(daysAgo: 120)]
        XCTAssertEqual(ChartRange.seven.filter(rows, now: now).compactMap(pace.value), [600])
        XCTAssertEqual(ChartRange.thirty.filter(rows, now: now).compactMap(pace.value), [600, 600])
        XCTAssertEqual(ChartRange.ninety.filter(rows, now: now).compactMap(pace.value), [600, 600, 600])
        XCTAssertEqual(ChartRange.all.filter(rows, now: now).compactMap(pace.value), [600, 600, 600, 600])
    }
    func testChartDoesNotNeedGPSOrHeartRateToShowAveragePace() {
        let run = row(minutes: 40, miles: 5)
        XCTAssertNil(run.averageHeartRate)
        XCTAssertEqual(pace.value(run), 480)
        XCTAssertEqual(chart(rows: [run]).closestWorkout(to: run.start)?.id, run.id)
    }
}
