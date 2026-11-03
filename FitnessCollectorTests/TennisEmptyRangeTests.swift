import XCTest
import SwiftUI
@testable import FitnessCollector

final class TennisEmptyRangeTests: XCTestCase {
    func testEmptyPresetsUseRequestedDatesRatherThanEpoch() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for (preset, days) in [(ChartRange.seven, 7), (.thirty, 30), (.ninety, 90), (.all, 365)] {
            let bounds = preset.emptyDateBounds(now: now, calendar: calendar)
            XCTAssertEqual(bounds.upperBound, now)
            XCTAssertEqual(bounds.lowerBound, calendar.date(byAdding: .day, value: -days, to: now))
            XCTAssertGreaterThan(ChartViewport.duration(bounds), 0)
            XCTAssertTrue(preset.filter([]).isEmpty)
        }
    }

    func testEmptyBoundsRespectCalendarDaysAcrossFallDST() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Indiana/Indianapolis")!
        let now = ISO8601DateFormatter().date(from: "2026-11-03T17:00:00Z")!
        let bounds = ChartRange.seven.emptyDateBounds(now: now, calendar: calendar)
        XCTAssertEqual(calendar.component(.hour, from: bounds.lowerBound), 12)
        XCTAssertEqual(calendar.component(.hour, from: bounds.upperBound), 12)
        XCTAssertEqual(ChartViewport.duration(bounds), 7 * 86400 + 3600)
    }

    func testEmptyChartsCannotSelectOrInventMeasurements() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let bounds = ChartRange.seven.emptyDateBounds(now: now)
        for metric in TennisActivityView.metrics {
            XCTAssertTrue(metric.plottableWorkouts(in: []).isEmpty)
            let chart = WorkoutMetricChart(
                title: metric.title, unit: metric.unit, workouts: [], chartRange: .seven,
                value: metric.value, onSelectWorkout: { _ in XCTFail("Empty chart selected a workout") },
                workoutNoun: "session", activityDates: [], fullDateRange: bounds,
                visibleDateRange: .constant(bounds), isScrollEnabled: .constant(false),
                emptyMessage: "No tennis sessions in this range.",
                selectionSummary: { _, _, _ in EmptyView() }
            )
            XCTAssertNil(chart.closestWorkout(to: now))
        }
    }
}
