import XCTest
@testable import FitnessCollector

final class ChartGeometryVisibleTests: XCTestCase {
    private struct Measurement {
        let date: Date
        let value: Double?
    }
    private let first = Date(timeIntervalSince1970: 1_700_000_000)
    private func measurement(_ offset: Double, _ value: Double?) -> Measurement {
        Measurement(date: first.addingTimeInterval(offset), value: value)
    }

    func testFiniteVisibleSubsetIsSharedByScalingAndSelection() {
        let items = [measurement(0, 10_000), measurement(10, nil), measurement(11, .nan),
                     measurement(12, .infinity), measurement(13, 120), measurement(20, 20_000)]
        let visible = first.addingTimeInterval(10)...first.addingTimeInterval(15)
        let plotted = ChartGeometry.visibleItems(items, in: visible, timestamp: \.date, value: \.value)
        XCTAssertEqual(plotted.count, 1)
        XCTAssertEqual(ChartGeometry.yDomain(plotted, value: \.value), 114...126)
        XCTAssertEqual(ChartGeometry.closestItem(to: first, in: plotted, timestamp: \.date)?.date, items[4].date)
    }

    func testNoFiniteVisibleMeasurementsHasFallbackAndNoHit() {
        let items = [measurement(0, 100), measurement(10, nil), measurement(11, .nan)]
        let visible = first.addingTimeInterval(10)...first.addingTimeInterval(15)
        let plotted = ChartGeometry.visibleItems(items, in: visible, timestamp: \.date, value: \.value)
        XCTAssertEqual(ChartGeometry.yDomain(plotted, value: \.value), 0...1)
        XCTAssertNil(ChartGeometry.closestItem(to: first, in: plotted, timestamp: \.date))
    }

    func testVisibleBoundaryIncludesBothEndsAndDuplicateDates() {
        let items = [measurement(0, 100), measurement(0, nil), measurement(0, 150), measurement(10, 120)]
        let plotted = ChartGeometry.visibleItems(items, in: first...first.addingTimeInterval(10), timestamp: \.date, value: \.value)
        XCTAssertEqual(plotted.count, 3)
        XCTAssertEqual(ChartGeometry.yDomain(plotted, value: \.value), 92.5...157.5)
        XCTAssertEqual(ChartGeometry.closestItem(to: first, in: plotted, timestamp: \.date)?.value, 100)
    }
}
