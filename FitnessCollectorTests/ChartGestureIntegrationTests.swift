import XCTest
import SwiftUI
import UIKit
@testable import FitnessCollector

/// Hosted bridge integration; real multi-touch still requires a physical-device pass.
@MainActor
final class ChartGestureIntegrationTests: XCTestCase {
    private let bounds = Date(timeIntervalSince1970: 0)...Date(timeIntervalSince1970: 100 * 86_400)

    private func fixture() -> (UIWindow, UIScrollView, ChartPlotGestures.PlotProbe, ChartPlotGestures.Coordinator) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let scroll = UIScrollView(frame: window.bounds)
        scroll.contentSize = CGSize(width: 400, height: 1600)
        window.addSubview(scroll)
        window.isHidden = false
        let probe = ChartPlotGestures.PlotProbe(frame: CGRect(x: 60, y: 100, width: 280, height: 180))
        probe.isUserInteractionEnabled = false
        scroll.addSubview(probe)
        let bridge = ChartPlotGestures(visible: .constant(bounds), bounds: bounds, onReset: {}, onTap: { _ in })
        let coordinator = ChartPlotGestures.Coordinator(bridge)
        coordinator.attach(to: probe)
        return (window, scroll, probe, coordinator)
    }

    func testActualSwiftUIChartLayoutAdmitsPinchOnDateLabels() async throws {
        let chart = { (title: String) in
            WorkoutMetricChart(
                title: title, unit: "bpm", workouts: [], chartRange: .all,
                value: { _ in nil }, onSelectWorkout: { _ in }, workoutNoun: "workout",
                fullDateRange: self.bounds, visibleDateRange: .constant(self.bounds),
                interactionID: "layout-regression", selectionSummary: { _, _, _ in EmptyView() })
        }
        let controller = UIHostingController(rootView: List {
            chart("First metric")
            chart("Second metric")
        })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 850))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        func probes(in view: UIView) -> [ChartPlotGestures.PlotProbe] {
            (view as? ChartPlotGestures.PlotProbe).map { [$0] } ?? view.subviews.flatMap { probes(in: $0) }
        }
        var plots: [ChartPlotGestures.PlotProbe] = []
        for _ in 0..<30 {
            controller.view.layoutIfNeeded()
            plots = probes(in: controller.view).filter { $0.bounds.height > 0 }
            if plots.count == 2 { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertEqual(plots.count, 2, "Exercise the actual List/Chart overlay, not synthetic plot rectangles")
        guard plots.count == 2 else { return }
        let plot = plots[0]
        var ancestor = plot.superview
        var coordinator: ChartPlotGestures.Coordinator?
        while let view = ancestor {
            coordinator = view.gestureRecognizers?.compactMap { $0.delegate as? ChartPlotGestures.Coordinator }
                .first { $0.probe === plot }
            if coordinator != nil { break }
            ancestor = view.superview
        }
        let bridge = try XCTUnwrap(coordinator)
        let dateLabel = CGPoint(x: plot.bounds.midX, y: plot.bounds.maxY + 8)
        XCTAssertFalse(bridge.contains(dateLabel), "Date labels are not workout tap targets")
        XCTAssertTrue(bridge.acceptsPinchTouch(at: dateLabel, in: plot), "The production chart must include its date labels in pinch hit testing")
        let touches = [plot.convert(dateLabel, to: window),
                       plots[1].convert(CGPoint(x: plots[1].bounds.midX, y: plots[1].bounds.midY), to: window)]
        XCTAssertTrue(bridge.ownsPinch(at: touches, in: window))
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

    func testNestedChartScrollContainersStillShareTheOuterListHost() {
        let (window, list, firstProbe, first) = fixture()
        let firstInner = UIScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 320))
        let secondInner = UIScrollView(frame: CGRect(x: 0, y: 320, width: 400, height: 320))
        list.addSubview(firstInner)
        list.addSubview(secondInner)
        firstInner.addSubview(firstProbe)
        first.attach(to: firstProbe)
        let secondProbe = ChartPlotGestures.PlotProbe(frame: CGRect(x: 60, y: 80, width: 280, height: 180))
        secondProbe.isUserInteractionEnabled = false
        secondInner.addSubview(secondProbe)
        let second = ChartPlotGestures.Coordinator(first.parent)
        second.attach(to: secondProbe)
        defer { second.detach(); first.detach(); window.isHidden = true }
        XCTAssertTrue(first.host === list)
        XCTAssertTrue(second.host === list)
        XCTAssertTrue(first.scrollView === list)
        let points = [CGPoint(x: 200, y: 190), CGPoint(x: 200, y: 490)]
        XCTAssertTrue(first.acceptsPinchTouch(at: points[1], in: list))
        XCTAssertTrue(first.ownsPinch(at: points, in: list))
        XCTAssertFalse(second.ownsPinch(at: points, in: list))
    }

    func testPinchCanCoexistWithInternalSwiftUIOrChartRecognizers() {
        let (window, _, probe, coordinator) = fixture()
        defer { coordinator.detach(); window.isHidden = true }
        let internalPan = UIPanGestureRecognizer()
        probe.addGestureRecognizer(internalPan)
        XCTAssertTrue(coordinator.gestureRecognizer(coordinator.pinch,
                                                   shouldRecognizeSimultaneouslyWith: internalPan))
        XCTAssertFalse(coordinator.gestureRecognizer(coordinator.pan,
                                                    shouldRecognizeSimultaneouslyWith: internalPan))
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

    func testPinchIncludesGraphAxesWithoutMakingThemWorkoutTapTargets() {
        let (window, scroll, _, coordinator) = fixture()
        coordinator.parent.pinchRegion = CGRect(x: -48, y: 0, width: 328, height: 220)
        let (_, second) = sibling(in: scroll, matching: coordinator)
        defer { second.detach(); coordinator.detach(); window.isHidden = true }
        let dateAxis = CGPoint(x: 200, y: 300)
        let valueAxis = CGPoint(x: 35, y: 490)
        XCTAssertTrue(coordinator.acceptsPinchTouch(at: dateAxis, in: scroll))
        XCTAssertTrue(coordinator.acceptsPinchTouch(at: valueAxis, in: scroll))
        XCTAssertFalse(coordinator.contains(CGPoint(x: 140, y: 200)), "Date labels must not select workouts")
        XCTAssertFalse(second.contains(CGPoint(x: -25, y: 90)), "Value labels must not select workouts")
        XCTAssertTrue(coordinator.ownsPinch(at: [dateAxis, valueAxis], in: scroll))
        XCTAssertFalse(second.ownsPinch(at: [dateAxis, valueAxis], in: scroll))
        XCTAssertFalse(coordinator.acceptsPinchTouch(at: CGPoint(x: 200, y: 350), in: scroll), "Gap between graphs stays excluded")
        scroll.contentOffset.y = 600
        XCTAssertFalse(coordinator.acceptsPinchTouch(at: valueAxis, in: scroll), "Offscreen axes stay excluded")
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

    private func screen(in window: UIWindow, matching plot: ChartPlotGestures.Coordinator)
        -> (ChartPlotGestures.PlotProbe, ChartPlotGestures.Coordinator) {
        let probe = ChartPlotGestures.PlotProbe(frame: window.bounds)
        probe.isUserInteractionEnabled = false
        window.addSubview(probe)
        var bridge = plot.parent
        bridge.isScreenWide = true
        bridge.pinchRegion = nil
        let coordinator = ChartPlotGestures.Coordinator(bridge)
        coordinator.attach(to: probe)
        return (probe, coordinator)
    }

    func testScreenPinchAddsGapsHeadingsAndRowsWithoutAddingTapOrPanTargets() {
        let (window, scroll, _, first) = fixture()
        let (_, second) = sibling(in: scroll, matching: first)
        let (_, screen) = screen(in: window, matching: first)
        defer { screen.detach(); second.detach(); first.detach(); window.isHidden = true }
        XCTAssertTrue(screen.host === window)
        XCTAssertEqual(screen.recognizers.count, 1)
        XCTAssertTrue(screen.pinch.view === window)
        XCTAssertNil(screen.pan.view)
        XCTAssertNil(screen.singleTap.view)
        XCTAssertFalse(first.acceptsPinchTouch(at: CGPoint(x: 20, y: 50), in: window),
                       "Plot recognizers must not start tracking screen-only touches")
        XCTAssertTrue(screen.acceptsPinchTouch(at: CGPoint(x: 20, y: 50), in: window))
        for points in [[CGPoint(x: 20, y: 50), CGPoint(x: 380, y: 350)],
                       [CGPoint(x: 200, y: 190), CGPoint(x: 20, y: 350)],
                       [CGPoint(x: 60, y: 650), CGPoint(x: 340, y: 740)]] {
            for order in [points, points.reversed().map { $0 }] {
                XCTAssertTrue(screen.ownsPinch(at: order, in: window))
                XCTAssertFalse(first.ownsPinch(at: order, in: window))
                XCTAssertFalse(second.ownsPinch(at: order, in: window))
            }
        }
        let charts = [CGPoint(x: 150, y: 190), CGPoint(x: 250, y: 490)]
        XCTAssertTrue(first.ownsPinch(at: charts, in: window))
        XCTAssertFalse(second.ownsPinch(at: charts, in: window))
        XCTAssertFalse(screen.ownsPinch(at: charts, in: window), "No double application of zoom")
        XCTAssertFalse(screen.ownsPinch(at: [CGPoint(x: -1, y: 100), CGPoint(x: 200, y: 300)], in: window))
    }

    func testScreenPinchWorksWhenChartCellsAreOffscreenAndRestoresScrolling() {
        let (window, scroll, _, plot) = fixture()
        var visible = bounds
        plot.parent = ChartPlotGestures(visible: Binding(get: { visible }, set: { visible = $0 }),
                                         bounds: bounds, onReset: {}, onTap: { _ in })
        let (_, screen) = screen(in: window, matching: plot)
        defer { screen.detach(); plot.detach(); window.isHidden = true }
        let unrelated = UIScrollView(frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        window.addSubview(unrelated)
        scroll.contentOffset.y = 700
        XCTAssertTrue(screen.ownsPinch(at: [CGPoint(x: 100, y: 200), CGPoint(x: 300, y: 400)], in: window))
        for ending: UIGestureRecognizer.State in [.ended, .cancelled, .failed] {
            screen.handlePinch(state: .began, scale: 1, location: CGPoint(x: 200, y: 300), width: 400)
            XCTAssertFalse(scroll.isScrollEnabled)
            XCTAssertTrue(unrelated.isScrollEnabled, "Freeze only this Activity List, not every intersecting scroll view")
            XCTAssertFalse(plot.pan.isEnabled)
            screen.handlePinch(state: .changed, scale: 2, location: CGPoint(x: 200, y: 300), width: 400)
            // SwiftUI updates during a pinch must not re-enable suspended chart pans.
            plot.update(plot.parent)
            XCTAssertFalse(plot.pan.isEnabled)
            screen.handlePinch(state: ending, scale: 2, location: CGPoint(x: 200, y: 300), width: 400)
            XCTAssertTrue(scroll.isScrollEnabled)
            XCTAssertTrue(plot.pan.isEnabled)
        }
        XCTAssertLessThan(ChartViewport.duration(visible), ChartViewport.duration(bounds))
    }

    func testDisablingOrRemovingScreenProbeRestoresScrollAndStopsOwningTouches() {
        let (window, scroll, _, plot) = fixture()
        let (probe, screen) = screen(in: window, matching: plot)
        defer { screen.detach(); plot.detach(); window.isHidden = true }
        let points = [CGPoint(x: 20, y: 50), CGPoint(x: 380, y: 350)]
        screen.handlePinch(state: .began, scale: 1, location: .zero, width: 400)
        var disabled = screen.parent
        disabled.isEnabled = false
        screen.update(disabled)
        XCTAssertTrue(scroll.isScrollEnabled)
        XCTAssertTrue(plot.pan.isEnabled)
        XCTAssertFalse(screen.pinch.isEnabled)
        var changedWhileHidden = disabled
        changedWhileHidden.interactionID = "changed-while-hidden"
        screen.update(changedWhileHidden)
        XCTAssertFalse(screen.pinch.isEnabled, "Context changes must not reactivate an invisible screen")
        screen.update(disabled)
        XCTAssertFalse(screen.ownsPinch(at: points, in: window))
        XCTAssertFalse(plot.acceptsPinchTouch(at: points[0], in: window))
        disabled.isEnabled = true
        screen.update(disabled)
        XCTAssertTrue(screen.ownsPinch(at: points, in: window))
        probe.isHidden = true
        XCTAssertFalse(screen.ownsPinch(at: points, in: window))
        probe.isHidden = false
        screen.handlePinch(state: .began, scale: 1, location: .zero, width: 400)
        screen.detach()
        XCTAssertTrue(scroll.isScrollEnabled)
        XCTAssertTrue(plot.pan.isEnabled)
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
