import XCTest
import HealthKit
@testable import FitnessCollector

final class LiftingTrendsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func row(daysAgo: Int = 0, type: HKWorkoutActivityType = .traditionalStrengthTraining,
                     calories: Double? = nil, heartRate: Double? = nil) -> WorkoutRow {
        let start = now.addingTimeInterval(-Double(daysAgo) * 86400)
        let workout = HKWorkout(activityType: type, start: start, end: start.addingTimeInterval(2700))
        return WorkoutRow(id: workout.uuid, hkWorkout: workout, activityType: type, start: start,
                          durationMinutes: 45, calories: calories, distanceMiles: nil,
                          averageHeartRate: heartRate, maxHeartRate: heartRate.map { $0 + 30 })
    }

    func testLiftingMetricsUseSessionMeasurements() {
        let workout = row(calories: 250, heartRate: 110)
        XCTAssertEqual(LiftingActivityView.metrics.map { $0.value(workout) }, [45, 250, 110, 140])
        XCTAssertEqual(Set(LiftingActivityView.metrics.map(\.id)).count, 4)
    }

    func testMissingMeasurementsAreNotReplacedWithZero() {
        let workout = row()
        XCTAssertEqual(LiftingActivityView.metrics.map { $0.value(workout) }, [45, nil, nil, nil])
        XCTAssertTrue(LiftingActivityView.metrics[1].plottableWorkouts(in: [workout]).isEmpty)
    }

    func testSelectionUsesOnlyPlottedSessions() {
        let measured = row(daysAgo: 1, heartRate: 110)
        let missing = row()
        let invalid = row(heartRate: .nan)
        let metric = LiftingActivityView.metrics[2]
        let plotted = metric.plottableWorkouts(in: [measured, missing, invalid])
        let chart = WorkoutMetricChart(
            title: metric.title, unit: metric.unit, workouts: plotted, chartRange: .thirty,
            value: metric.value, onSelectWorkout: { _ in }, workoutNoun: "session",
            selectionSummary: { LiftingSelectionSummary(workout: $0, unit: $1, value: $2) }
        )
        XCTAssertEqual(plotted.map(\.id), [measured.id])
        XCTAssertEqual(chart.closestWorkout(to: missing.start)?.id, measured.id)
    }

    func testRangesIncludeBoundaryAndAllHistory() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let workouts = [row(daysAgo: 0), row(daysAgo: 7), row(daysAgo: 8), row(daysAgo: 30),
                        row(daysAgo: 31), row(daysAgo: 90), row(daysAgo: 91)]
        XCTAssertEqual(ChartRange.seven.filter(workouts, now: now, calendar: calendar).count, 2)
        XCTAssertEqual(ChartRange.thirty.filter(workouts, now: now, calendar: calendar).count, 4)
        XCTAssertEqual(ChartRange.ninety.filter(workouts, now: now, calendar: calendar).count, 6)
        XCTAssertEqual(ChartRange.all.filter(workouts, now: now, calendar: calendar).count, 7)
    }

    func testLiftingMembershipIncludesAllExistingStrengthTypes() {
        let types: [HKWorkoutActivityType] = [.traditionalStrengthTraining, .functionalStrengthTraining,
                                             .coreTraining, .crossTraining, .highIntensityIntervalTraining]
        let workouts = types.map { row(type: $0) } + [row(type: .running), row(type: .tennis)]
        XCTAssertEqual(Set(workouts.inCategory(.lifting).map(\.activityType)), Set(types))
    }
}
