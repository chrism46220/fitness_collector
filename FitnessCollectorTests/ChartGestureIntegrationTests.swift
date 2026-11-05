import XCTest
import SwiftUI
import UIKit
@testable import FitnessCollector

/// Hosted bridge integration; real multi-touch synthesis still requires a simulator UI pass.
@MainActor
final class ChartGestureIntegrationTests: XCTestCase {
    private let bounds = Date(timeIntervalSince1970: 0)...Date(timeIntervalSince1970: 100 * 86_400)

    private func fixture() -> (UIWindow, UIScrollView, ChartPlotGestures.PlotProbe, ChartPlotGestures.Coordinator) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let scroll = UIScrollView(frame: window.bounds)
        scroll.contentSize = CGSize(width: 400, height: 1600)
        window.addSubview(scroll)
        let probe = ChartPlotGestures.PlotProbe(frame: CGRect(x: 60, y: 100, width: 280, height: 180))
        probe.isUserInteractionEnabled = false
        scroll.addSubview(probe)
        let bridge = ChartPlotGestures(visible: .constant(bounds), bounds: bounds, onReset: {}, onTap: { _ in })
        let coordinator = ChartPlotGestures.Coordinator(bridge)
        coordinator.attach(to: probe)
        return (window, scroll, probe, coordinator)
    }

    func testProbePassesHitTestingAndRecognizersAttachToListAncestor() {
        let (window, scroll, probe, coordinator) = fixture()
        defer { coordinator.detach(); window.isHidden = true }
        XCTAssertNil(probe.hitTest(CGPoint(x: 10, y: 10), with: nil))
        XCTAssertTrue(coordinator.host === scroll)
        XCTAssertTrue(coordinator.recognizers.allSatisfy { $0.view === scroll })
        XCTAssertEqual(coordinator.recognizers.count, 4)
        XCTAssertEqual(coordinator.pan.maximumNumberOfTouches, 1)
        XCTAssertEqual(coordinator.doubleTap.numberOfTapsRequired, 2)
    }

    func testPlotBoundsExcludeAxesAndControlsAndClipScrolledOffPlot() {
        let (window, scroll, _, coordinator) = fixture()
        defer { coordinator.detach(); window.isHidden = true }
        XCTAssertTrue(coordinator.contains(CGPoint(x: 140, y: 90)))
        XCTAssertFalse(coordinator.contains(CGPoint(x: -1, y: 90)))
        XCTAssertFalse(coordinator.contains(CGPoint(x: 140, y: -1)))
        XCTAssertFalse(coordinator.contains(CGPoint(x: 281, y: 90)))
        XCTAssertFalse(coordinator.contains(CGPoint(x: 140, y: 181)))
        scroll.contentOffset.y = 500
        XCTAssertFalse(coordinator.contains(CGPoint(x: 140, y: 90)))
    }

    func testListWaitsForDirectionalPanButDoesNotWaitForTapOrPinch() {
        let (window, scroll, _, coordinator) = fixture()
        defer { coordinator.detach(); window.isHidden = true }
        XCTAssertTrue(coordinator.gestureRecognizer(coordinator.pan, shouldBeRequiredToFailBy: scroll.panGestureRecognizer))
        XCTAssertFalse(coordinator.gestureRecognizer(coordinator.singleTap, shouldBeRequiredToFailBy: scroll.panGestureRecognizer))
        XCTAssertFalse(coordinator.gestureRecognizer(coordinator.doubleTap, shouldBeRequiredToFailBy: scroll.panGestureRecognizer))
        XCTAssertFalse(coordinator.gestureRecognizer(coordinator.pinch, shouldBeRequiredToFailBy: scroll.panGestureRecognizer))
        XCTAssertTrue(coordinator.gestureRecognizer(coordinator.pinch, shouldRecognizeSimultaneouslyWith: scroll.panGestureRecognizer))
    }

    func testPanAppliesFinalPositionThenStopsWithoutMomentumOrLateUpdates() {
        let (window, _, _, coordinator) = fixture()
        defer { coordinator.detach(); window.isHidden = true }
        var visible = Date(timeIntervalSince1970: 20 * 86_400)...Date(timeIntervalSince1970: 40 * 86_400)
        coordinator.parent = ChartPlotGestures(
            visible: Binding(get: { visible }, set: { visible = $0 }),
            bounds: bounds, onReset: {}, onTap: { _ in })
        let initial = visible
        coordinator.handlePan(state: .began, translation: 7, width: 280)
        coordinator.handlePan(state: .changed, translation: 35, width: 280)
        coordinator.handlePan(state: .ended, translation: 63, width: 280)
        let stopped = ChartViewport.pan(initial, in: bounds, translation: 56, width: 280)
        XCTAssertEqual(visible, stopped)
        coordinator.handlePan(state: .changed, translation: 140, width: 280)
        coordinator.handlePan(state: .ended, translation: 200, width: 280)
        XCTAssertEqual(visible, stopped)
    }

    func testCancelledPanDiscardsSnapshotAndNewPanStartsAtCurrentRange() {
        let (window, _, _, coordinator) = fixture()
        defer { coordinator.detach(); window.isHidden = true }
        var visible = Date(timeIntervalSince1970: 20 * 86_400)...Date(timeIntervalSince1970: 40 * 86_400)
        coordinator.parent = ChartPlotGestures(
            visible: Binding(get: { visible }, set: { visible = $0 }),
            bounds: bounds, onReset: {}, onTap: { _ in })
        coordinator.handlePan(state: .began, translation: 0, width: 280)
        coordinator.handlePan(state: .changed, translation: 28, width: 280)
        let stopped = visible
        coordinator.handlePan(state: .cancelled, translation: 140, width: 280)
        coordinator.handlePan(state: .changed, translation: 200, width: 280)
        XCTAssertEqual(visible, stopped)
        coordinator.handlePan(state: .began, translation: 12, width: 280)
        coordinator.handlePan(state: .ended, translation: -16, width: 280)
        XCTAssertEqual(visible, ChartViewport.pan(stopped, in: bounds, translation: -28, width: 280))
    }

    private func sibling(in scroll: UIScrollView, matching coordinator: ChartPlotGestures.Coordinator,
                         interactionID: String? = nil) -> (ChartPlotGestures.PlotProbe, ChartPlotGestures.Coordinator) {
        let probe = ChartPlotGestures.PlotProbe(frame: CGRect(x: 60, y: 400, width: 280, height: 180))
        probe.isUserInteractionEnabled = false
        scroll.addSubview(probe)
        var bridge = coordinator.parent
        if let interactionID { bridge.interactionID = interactionID }
        let sibling = ChartPlotGestures.Coordinator(bridge)
        sibling.attach(to: probe)
        return (probe, sibling)
    }

    func testCrossPlotPinchAcceptsBothPlotsButNotGapAxesOrOffscreenPlots() {
        let (window, scroll, _, coordinator) = fixture()
        let (secondProbe, second) = sibling(in: scroll, matching: coordinator)
        defer { second.detach(); coordinator.detach(); window.isHidden = true }
        XCTAssertTrue(coordinator.acceptsPinchTouch(at: CGPoint(x: 200, y: 190), in: scroll))
        XCTAssertTrue(coordinator.acceptsPinchTouch(at: CGPoint(x: 200, y: 490), in: scroll))
        XCTAssertFalse(coordinator.acceptsPinchTouch(at: CGPoint(x: 200, y: 340), in: scroll))
        XCTAssertFalse(coordinator.acceptsPinchTouch(at: CGPoint(x: 30, y: 490), in: scroll))
        secondProbe.isHidden = true
        XCTAssertFalse(coordinator.acceptsPinchTouch(at: CGPoint(x: 200, y: 490), in: scroll))
        secondProbe.isHidden = false
        scroll.contentOffset.y = 600
        XCTAssertFalse(coordinator.acceptsPinchTouch(at: CGPoint(x: 200, y: 490), in: scroll))
    }

    func testCrossPlotPinchHasExactlyOneOwnerRegardlessOfTouchOrder() {
        let (window, scroll, _, coordinator) = fixture()
        let (_, second) = sibling(in: scroll, matching: coordinator)
        defer { second.detach(); coordinator.detach(); window.isHidden = true }
        let points = [CGPoint(x: 150, y: 190), CGPoint(x: 250, y: 490)]
        for ordered in [points, Array(points.reversed())] {
            XCTAssertTrue(coordinator.ownsPinch(at: ordered, in: scroll))
            XCTAssertFalse(second.ownsPinch(at: ordered, in: scroll))
        }
        let samePlot = [CGPoint(x: 150, y: 460), CGPoint(x: 250, y: 520)]
        XCTAssertTrue(second.ownsPinch(at: samePlot, in: scroll))
        XCTAssertFalse(coordinator.ownsPinch(at: samePlot, in: scroll))
        XCTAssertFalse(coordinator.ownsPinch(at: [points[0]], in: scroll))
        XCTAssertFalse(coordinator.ownsPinch(at: [points[0], CGPoint(x: 200, y: 340)], in: scroll))
        XCTAssertTrue(coordinator.gestureRecognizer(coordinator.pinch, shouldRecognizeSimultaneouslyWith: second.pan))
    }

    func testUnrelatedAndDetachedPlotsCannotJoinPinch() {
        let (window, scroll, _, coordinator) = fixture()
        let (_, second) = sibling(in: scroll, matching: coordinator, interactionID: "different-category")
        defer { second.detach(); coordinator.detach(); window.isHidden = true }
        let point = CGPoint(x: 200, y: 490)
        XCTAssertFalse(coordinator.acceptsPinchTouch(at: point, in: scroll))
        var matching = second.parent
        matching.interactionID = coordinator.parent.interactionID
        second.update(matching)
        XCTAssertTrue(coordinator.acceptsPinchTouch(at: point, in: scroll))
        second.detach()
        XCTAssertFalse(coordinator.acceptsPinchTouch(at: point, in: scroll))
    }

    func testSharedPinchUpdatesViewportAndRestoresScrollingOnEveryExit() {
        for ending: UIGestureRecognizer.State in [.ended, .cancelled, .failed] {
            let (window, scroll, _, coordinator) = fixture()
            var visible = bounds
            coordinator.parent = ChartPlotGestures(
                visible: Binding(get: { visible }, set: { visible = $0 }),
                bounds: bounds, onReset: {}, onTap: { _ in })
            let (_, second) = sibling(in: scroll, matching: coordinator)
            coordinator.handlePinch(state: .began, scale: 1, location: CGPoint(x: 140, y: 240), width: 280)
            XCTAssertFalse(scroll.isScrollEnabled)
            XCTAssertFalse(coordinator.pan.isEnabled)
            XCTAssertFalse(second.pan.isEnabled)
            coordinator.handlePinch(state: .changed, scale: 2, location: CGPoint(x: 140, y: 240), width: 280)
            XCTAssertEqual(visible, ChartViewport.zoom(bounds, in: bounds, scale: 2, anchor: 0.5))
            XCTAssertEqual(second.parent.visible, visible)
            coordinator.handlePinch(state: ending, scale: 2, location: CGPoint(x: 140, y: 240), width: 280)
            XCTAssertTrue(scroll.isScrollEnabled)
            XCTAssertTrue(coordinator.pan.isEnabled)
            XCTAssertTrue(second.pan.isEnabled)
            let stopped = visible
            coordinator.handlePinch(state: .changed, scale: 4, location: .zero, width: 280)
            XCTAssertEqual(visible, stopped)
            second.detach()
            coordinator.detach()
            window.isHidden = true
        }
    }

    func testRemovingPinchOwnerRestoresSiblingPanAndListScrolling() {
        let (window, scroll, _, coordinator) = fixture()
        let (_, second) = sibling(in: scroll, matching: coordinator)
        defer { second.detach(); coordinator.detach(); window.isHidden = true }
        coordinator.handlePinch(state: .began, scale: 1, location: .zero, width: 280)
        XCTAssertFalse(scroll.isScrollEnabled)
        coordinator.detach()
        XCTAssertTrue(scroll.isScrollEnabled)
        XCTAssertTrue(second.pan.isEnabled)
    }

    func testDismantleRemovesOnlyChartRecognizersAndReattachDoesNotAccumulate() {
        let (window, scroll, probe, coordinator) = fixture()
        defer { window.isHidden = true }
        let initialCount = scroll.gestureRecognizers?.count
        for _ in 0..<5 { coordinator.attach(to: probe) }
        XCTAssertEqual(scroll.gestureRecognizers?.count, initialCount)
        coordinator.detach()
        XCTAssertTrue(coordinator.recognizers.allSatisfy { $0.view == nil })
        XCTAssertTrue(scroll.gestureRecognizers?.contains(scroll.panGestureRecognizer) == true)
        coordinator.attach(to: probe)
        XCTAssertEqual(scroll.gestureRecognizers?.count, initialCount)
        coordinator.detach()
    }
}
