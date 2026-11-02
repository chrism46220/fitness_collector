import XCTest
@testable import FitnessCollector

final class ChartViewportTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)
    private func date(_ days: Double) -> Date { origin.addingTimeInterval(days * ChartViewport.day) }
    private func range(_ first: Double, _ last: Double) -> ClosedRange<Date> { date(first)...date(last) }
    private func assertRange(_ actual: ClosedRange<Date>, _ first: Double, _ last: Double,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.lowerBound.timeIntervalSince(origin) / ChartViewport.day, first, accuracy: 1e-8, file: file, line: line)
        XCTAssertEqual(actual.upperBound.timeIntervalSince(origin) / ChartViewport.day, last, accuracy: 1e-8, file: file, line: line)
    }
    private func context(_ preset: String = "All", category: String = "running", extent: ClosedRange<Date>? = nil) -> ChartViewportContext {
        ChartViewportContext(category: category, preset: preset, extent: extent ?? range(0, 100))
    }

    func testBoundsUseAllDatesRegardlessOfOrderAndDuplicates() {
        assertRange(ChartViewport.bounds(for: [date(100), date(0), date(5), date(100)]), 0, 100)
    }

    func testEmptySingleAndCoincidentDatesHaveUsableDomains() {
        XCTAssertEqual(ChartViewport.duration(ChartViewport.bounds(for: [])), ChartViewport.day)
        assertRange(ChartViewport.bounds(for: [date(0)]), -0.5, 0.5)
        assertRange(ChartViewport.bounds(for: [date(0), date(0)]), -0.5, 0.5)
        assertRange(ChartViewport.bounds(for: [date(0), date(0.25)]), -0.375, 0.625)
    }

    func testPinchKeepsDateUnderOffCenterAnchor() {
        let result = ChartViewport.zoom(range(0, 100), in: range(0, 100), scale: 2, anchor: 0.25)
        assertRange(result, 12.5, 62.5)
        XCTAssertEqual(result.lowerBound.addingTimeInterval(ChartViewport.duration(result) * 0.25), date(25))
    }

    func testPinchFollowsMovingCentroid() {
        assertRange(ChartViewport.zoom(range(0, 100), in: range(0, 100), scale: 2,
                                       anchor: 0.25, currentAnchor: 0.5), 0, 50)
    }

    func testPinchClampsToMinimumSpanAndBounds() {
        assertRange(ChartViewport.zoom(range(0, 100), in: range(0, 100), scale: 1_000, anchor: 0.5), 49.5, 50.5)
        assertRange(ChartViewport.zoom(range(20, 40), in: range(0, 100), scale: 0.01, anchor: 0.3), 0, 100)
        assertRange(ChartViewport.zoom(range(0, 10), in: range(0, 100), scale: 2, anchor: 0), 0, 5)
        assertRange(ChartViewport.zoom(range(90, 100), in: range(0, 100), scale: 2, anchor: 1), 95, 100)
    }

    func testInvalidPinchAndPanInputsDoNotCorruptDates() {
        for scale in [0, -1, .infinity, .nan] {
            assertRange(ChartViewport.zoom(range(20, 40), in: range(0, 100), scale: scale, anchor: 0.5), 20, 40)
        }
        for width in [0, -1, .infinity, .nan] {
            assertRange(ChartViewport.pan(range(20, 40), in: range(0, 100), translation: 10, width: width), 20, 40)
        }
    }

    func testPanDirectionAndClampsPreserveSpan() {
        assertRange(ChartViewport.pan(range(20, 40), in: range(0, 100), translation: 50, width: 200), 15, 35)
        assertRange(ChartViewport.pan(range(20, 40), in: range(0, 100), translation: -50, width: 200), 25, 45)
        assertRange(ChartViewport.pan(range(20, 40), in: range(0, 100), translation: 5_000, width: 200), 0, 20)
        assertRange(ChartViewport.pan(range(20, 40), in: range(0, 100), translation: -5_000, width: 200), 80, 100)
    }

    func testRepeatedGestureUpdatesUseSnapshotWithoutDrift() {
        let initial = range(20, 80)
        let expected = ChartViewport.pan(initial, in: range(0, 100), translation: 50, width: 300)
        for translation in 0...50 {
            let result = ChartViewport.pan(initial, in: range(0, 100), translation: Double(translation), width: 300)
            if translation == 50 { XCTAssertEqual(result, expected) }
        }
        let zoomed = ChartViewport.zoom(initial, in: range(0, 100), scale: 2, anchor: 0.5)
        let restored = ChartViewport.zoom(zoomed, in: range(0, 100), scale: 0.5, anchor: 0.5)
        XCTAssertEqual(restored, initial)
    }

    func testClampHandlesOversizedAndDisjointWindows() {
        assertRange(ChartViewport.clamp(range(-200, 200), to: range(0, 100)), 0, 100)
        assertRange(ChartViewport.clamp(range(200, 220), to: range(0, 100)), 80, 100)
        assertRange(ChartViewport.clamp(range(-40, -20), to: range(0, 100)), 0, 20)
        assertRange(ChartViewport.clamp(range(10, 10), to: range(0, 100)), 10, 11)
    }

    func testSingleDateCannotZoomIntoInvalidDomain() {
        let bounds = ChartViewport.bounds(for: [date(0)])
        XCTAssertEqual(ChartViewport.zoom(bounds, in: bounds, scale: 100, anchor: 0), bounds)
        XCTAssertFalse(ChartViewport.isZoomed(bounds, in: bounds))
    }

    func testEveryPresetAndCategoryChangeResetsViewport() {
        for preset in ["7D", "30D", "90D", "All"] {
            var state = ChartViewportState(context: context("previous"))
            state.visible = range(10, 20)
            state.scrollEnabled = true
            state.reconcile(context(preset, extent: range(5, 75)))
            assertRange(state.visible, 5, 75)
            XCTAssertFalse(state.scrollEnabled)
        }
        var state = ChartViewportState(context: context())
        state.visible = range(10, 20)
        state.reconcile(context(category: "lifting"))
        assertRange(state.visible, 0, 100)
    }

    func testSameExtentDuringHeartRateEnrichmentPreservesViewportAndMode() {
        var state = ChartViewportState(context: context())
        state.visible = range(10, 20)
        state.scrollEnabled = true
        state.reconcile(context())
        assertRange(state.visible, 10, 20)
        XCTAssertTrue(state.scrollEnabled)
    }

    func testExtentChangesClampZoomAndExpandFullRange() {
        var state = ChartViewportState(context: context())
        state.visible = range(10, 20)
        state.reconcile(context(extent: range(15, 120)))
        assertRange(state.visible, 15, 25)
        state.reconcile(context(extent: range(-20, 120)))
        assertRange(state.visible, 15, 25)
        state.reset()
        state.reconcile(context(extent: range(-20, 150)))
        assertRange(state.visible, -20, 150)
    }

    func testResetRestoresCurrentPresetAndClearsScrollMode() {
        var state = ChartViewportState(context: context("7D", extent: range(0, 7)))
        state.visible = range(3, 5)
        state.scrollEnabled = true
        state.reset()
        assertRange(state.visible, 0, 7)
        XCTAssertFalse(state.scrollEnabled)
    }

    func testRecentDetailUsesDistinctDatesAndAvailableWidth() {
        let dates = (0...100).map { date(Double($0)) }
        assertRange(ChartViewport.recentDetail(in: range(0, 100), dates: dates, width: 290), 96, 100)
        assertRange(ChartViewport.recentDetail(in: range(0, 100), dates: dates, width: 580), 91, 100)
        XCTAssertEqual(ChartViewport.recentDetail(in: range(0, 100), dates: [date(0), date(100), date(100)], width: 290), range(0, 100))
    }

    func testPanPolicyRejectsVerticalDiagonalStationaryAndFullRange() {
        XCTAssertTrue(ChartGesturePolicy.acceptsPan(zoomed: true, x: 300, y: 10))
        XCTAssertTrue(ChartGesturePolicy.acceptsPan(zoomed: true, x: -300, y: 10))
        XCTAssertFalse(ChartGesturePolicy.acceptsPan(zoomed: true, x: 10, y: 300))
        XCTAssertFalse(ChartGesturePolicy.acceptsPan(zoomed: true, x: 100, y: 100))
        XCTAssertFalse(ChartGesturePolicy.acceptsPan(zoomed: true, x: 0, y: 0))
        XCTAssertFalse(ChartGesturePolicy.acceptsPan(zoomed: false, x: 300, y: 0))
    }
}

final class ChartDateAxisTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private let locale = Locale(identifier: "en_US_POSIX")
    private var start: Date { calendar.date(from: DateComponents(year: 2010, month: 1, day: 1))! }
    private func ticks(days: Double, width: Double) -> [ChartDateAxis.Tick] {
        ChartDateAxis.ticks(in: start...start.addingTimeInterval(days * ChartViewport.day), width: width, calendar: calendar, locale: locale)
    }

    func testDensityUsesPlotWidthAndHasHardCap() {
        XCTAssertEqual(ticks(days: 90, width: 260).count, 2)
        XCTAssertEqual(ticks(days: 90, width: 400).count, 4)
        XCTAssertEqual(ticks(days: 90, width: 5_000).count, 6)
        XCTAssertEqual(ticks(days: 90, width: 40).count, 1)
        XCTAssertTrue(ticks(days: 90, width: 0).isEmpty)
    }

    func testMultiYearAxisHasDistinctBoundedLabelsAndYearContext() {
        for width in [200.0, 320, 600] {
            let labels = ticks(days: 365 * 16, width: width)
            XCTAssertLessThanOrEqual(labels.count, 6)
            XCTAssertEqual(Set(labels.map(\.label)).count, labels.count)
            for tick in labels {
                XCTAssertEqual(tick.label, String(calendar.component(.year, from: tick.date)))
            }
        }
    }

    func testZoomedAllUsesDayLabelsAndAlwaysShowsYear() {
        let labels = ticks(days: 7, width: 320)
        XCTAssertEqual(labels.count, 3)
        for label in labels {
            XCTAssertTrue(label.label.hasPrefix("Jan"))
            XCTAssertTrue(label.label.contains("2010"))
        }
    }

    func testMonthAndShortDurationFormatsAdapt() {
        XCTAssertTrue(ticks(days: 365, width: 320).allSatisfy { $0.label.contains("\n2010") })
        XCTAssertTrue(ticks(days: 1, width: 320).allSatisfy { $0.label.contains(":") && $0.label.contains("2010") })
    }

    func testLabelsFitNonoverlappingInteriorCells() {
        for days in [1.0, 7, 30, 90, 365, 3650] {
            for width in [180.0, 280, 600] {
                let labels = ticks(days: days, width: width)
                let duration = days * ChartViewport.day
                let positions = labels.map { $0.date.timeIntervalSince(start) / duration * width }
                XCTAssertGreaterThanOrEqual(positions.first!, 44)
                XCTAssertLessThanOrEqual(positions.last!, width - 44)
                for pair in zip(positions, positions.dropFirst()) { XCTAssertGreaterThanOrEqual(pair.1 - pair.0, 88 - 0.001) }
            }
        }
    }
}
