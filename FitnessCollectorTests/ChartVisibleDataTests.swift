import XCTest
import SwiftUI
import HealthKit
@testable import FitnessCollector

final class ChartVisibleDataTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private func row(day: Double, hr: Double?) -> WorkoutRow {
        let start = base.addingTimeInterval(day * ChartViewport.day)
        let workout = HKWorkout(activityType: .running, start: start, end: start.addingTimeInterval(1800))
        return WorkoutRow(id: workout.uuid, hkWorkout: workout, activityType: .running, start: start,
                          durationMinutes: 30, calories: nil, distanceMiles: 3,
                          averageHeartRate: hr, maxHeartRate: nil)
    }
    private func chart(_ rows: [WorkoutRow], visible: ClosedRange<Date>) -> WorkoutMetricChart<EmptyView> {
        WorkoutMetricChart(title: "HR", unit: "bpm", workouts: rows, chartRange: .all,
                           value: \.averageHeartRate, onSelectWorkout: { _ in }, workoutNoun: "run",
                           fullDateRange: ChartViewport.bounds(for: rows.map(\.start)),
                           visibleDateRange: .constant(visible),
                           selectionSummary: { _, _, _ in EmptyView() })
    }

    func testOffscreenExtremeCannotAffectYScaleOrSelection() {
        let rows = [row(day: 0, hr: 10_000), row(day: 10, hr: 120), row(day: 20, hr: 20_000)]
        let chart = chart(rows, visible: rows[1].start...rows[1].start.addingTimeInterval(ChartViewport.day))
        XCTAssertEqual(chart.yDomain(), 114...126)
        XCTAssertEqual(chart.closestWorkout(to: rows[0].start)?.id, rows[1].id)
    }

    func testMissingAndNonfiniteValuesNeverReceiveTapsOrAffectScale() {
        let rows = [row(day: 0, hr: nil), row(day: 1, hr: .nan), row(day: 2, hr: .infinity), row(day: 3, hr: 100)]
        let chart = chart(rows, visible: rows[0].start...rows[3].start)
        XCTAssertEqual(chart.yDomain(), 95...105)
        XCTAssertEqual(chart.closestWorkout(to: rows[0].start)?.id, rows[3].id)
    }

    func testEmptyVisibleWindowHasFallbackAndNoSelection() {
        let rows = [row(day: 0, hr: 100), row(day: 10, hr: 120)]
        let visible = base.addingTimeInterval(ChartViewport.day)...base.addingTimeInterval(2 * ChartViewport.day)
        XCTAssertEqual(chart(rows, visible: visible).yDomain(), 0...1)
        XCTAssertNil(chart(rows, visible: visible).closestWorkout(to: base))
    }

    func testDuplicateDatesKeepFiniteMeasurementsAndStableTieOrder() {
        let rows = [row(day: 0, hr: nil), row(day: 0, hr: 100), row(day: 0, hr: 150)]
        let visible = ChartViewport.bounds(for: rows.map(\.start))
        XCTAssertEqual(chart(rows, visible: visible).yDomain(), 92.5...157.5)
        XCTAssertEqual(chart(rows, visible: visible).closestWorkout(to: base)?.id, rows[1].id)
    }

    func testMissingHRAtExtentsDoesNotChangeSharedDateDomainAfterEnrichment() {
        let rows = [row(day: 0, hr: nil), row(day: 10, hr: 100), row(day: 20, hr: nil)]
        let bounds = ChartViewport.bounds(for: rows.map(\.start))
        var state = ChartViewportState(context: ChartViewportContext(category: "running", preset: "All", extent: bounds))
        state.visible = base.addingTimeInterval(5 * ChartViewport.day)...base.addingTimeInterval(15 * ChartViewport.day)
        let before = state.visible
        let enriched = [row(day: 0, hr: 110), row(day: 10, hr: 100), row(day: 20, hr: 120)]
        state.reconcile(ChartViewportContext(category: "running", preset: "All", extent: ChartViewport.bounds(for: enriched.map(\.start))))
        XCTAssertEqual(state.visible, before)
        XCTAssertEqual(chart(rows, visible: state.visible).visibleDateRange, chart(enriched, visible: state.visible).visibleDateRange)
    }
}
