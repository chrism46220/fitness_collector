import SwiftUI
import UIKit

/// A non-hit-testing geometry probe. Recognizers live on the enclosing List's
/// UIScrollView (or window when hosted outside a List), never on an overlay that
/// could intercept scrolling. Each recognizer admits touches only inside this plot.
struct ChartPlotGestures: UIViewRepresentable {
    @Binding var visible: ClosedRange<Date>
    let bounds: ClosedRange<Date>
    var interactionID = ""
    let onReset: () -> Void
    let onTap: (Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PlotProbe {
        let view = PlotProbe()
        view.isUserInteractionEnabled = false
        view.onMove = { [weak coordinator = context.coordinator] probe in
            coordinator?.attach(to: probe)
        }
        context.coordinator.probe = view
        return view
    }

    func updateUIView(_ view: PlotProbe, context: Context) {
        context.coordinator.update(self)
        context.coordinator.attach(to: view)
    }

    static func dismantleUIView(_ view: PlotProbe, coordinator: Coordinator) {
        view.onMove = nil
        coordinator.detach()
    }

    final class PlotProbe: UIView {
        var onMove: ((PlotProbe) -> Void)?
        override func didMoveToWindow() { super.didMoveToWindow(); onMove?(self) }
        override func layoutSubviews() { super.layoutSubviews(); onMove?(self) }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: ChartPlotGestures
        weak var probe: PlotProbe?
        weak var host: UIView?
        weak var scrollView: UIScrollView?
        let pinch = UIPinchGestureRecognizer()
        let pan = UIPanGestureRecognizer()
        let singleTap = UITapGestureRecognizer()
        let doubleTap = UITapGestureRecognizer()
        private var pinchSnapshot: ClosedRange<Date>?
        private var panSnapshot: ClosedRange<Date>?
        private var anchor = 0.5
        private var initialTranslation: CGFloat = 0
        private var initialScale: CGFloat = 1
        private var gestureWidth: CGFloat = 1
        private var suspendedScroll: (view: UIScrollView, wasEnabled: Bool)?

        init(_ parent: ChartPlotGestures) {
            self.parent = parent
            super.init()
            pan.maximumNumberOfTouches = 1
            doubleTap.numberOfTapsRequired = 2
            singleTap.require(toFail: doubleTap)
            singleTap.require(toFail: pan)
            singleTap.require(toFail: pinch)
            for recognizer in recognizers {
                recognizer.delegate = self
                recognizer.cancelsTouchesInView = false
            }
            pinch.addTarget(self, action: #selector(pinched))
            pan.addTarget(self, action: #selector(panned))
            singleTap.addTarget(self, action: #selector(tapped))
            doubleTap.addTarget(self, action: #selector(reset))
        }

        var recognizers: [UIGestureRecognizer] { [pinch, pan, singleTap, doubleTap] }

        func update(_ next: ChartPlotGestures) {
            if parent.bounds != next.bounds || parent.interactionID != next.interactionID {
                // A preset/extent changed mid-gesture. Discard its old snapshot.
                pinchSnapshot = nil
                panSnapshot = nil
                restoreListScrolling()
                for recognizer in recognizers { recognizer.isEnabled = false; recognizer.isEnabled = true }
            }
            parent = next
        }

        func attach(to probe: PlotProbe) {
            self.probe = probe
            guard probe.window != nil else { detach(); return }
            var ancestor = probe.superview
            var scroll: UIScrollView?
            while let view = ancestor {
                if let candidate = view as? UIScrollView { scroll = candidate; break }
                ancestor = view.superview
            }
            guard let target: UIView = scroll ?? probe.window, target !== host else { return }
            detach()
            host = target
            scrollView = scroll
            recognizers.forEach { target.addGestureRecognizer($0) }
        }

        func detach() {
            restoreListScrolling()
            recognizers.forEach { $0.view?.removeGestureRecognizer($0) }
            host = nil
            scrollView = nil
            pinchSnapshot = nil
            panSnapshot = nil
            pan.isEnabled = true
        }

        private func restoreListScrolling() {
            if let suspendedScroll {
                suspendedScroll.view.isScrollEnabled = suspendedScroll.wasEnabled
                self.suspendedScroll = nil
            }
        }

        func contains(_ location: CGPoint) -> Bool {
            guard let probe, let window = probe.window, !probe.isHidden,
                  probe.bounds.width > 0, probe.bounds.height > 0,
                  probe.bounds.contains(location) else { return false }
            let point = probe.convert(location, to: window)
            if let scrollView, !scrollView.bounds.contains(window.convert(point, to: scrollView)) { return false }
            return window.bounds.contains(point)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let probe, contains(touch.location(in: probe)) else { return false }
            // Also protects controls if this reusable bridge is ever hosted over one.
            var view = touch.view
            while let current = view, current !== host {
                if current is UIControl { return false }
                view = current.superview
            }
            return true
        }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let probe else { return false }
            if recognizer === pan {
                let velocity = pan.velocity(in: probe)
                return ChartGesturePolicy.acceptsPan(zoomed: ChartViewport.isZoomed(parent.visible, in: parent.bounds),
                                                     x: velocity.x, y: velocity.y)
            }
            return true
        }

        // Apple: shouldBeRequiredToFailBy makes OTHER wait for this recognizer.
        // https://developer.apple.com/documentation/uikit/preferring-one-gesture-over-another
        // Only the directional pan delays the List. Waiting for a pinch to fail
        // would hold a one-finger vertical scroll until the finger lifted.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            recognizer === pan && other === scrollView?.panGestureRecognizer
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            (recognizer === pinch && (other === scrollView?.panGestureRecognizer || other === pan))
                || (recognizer === pan && other === pinch)
        }

        @objc func pinched() {
            guard let probe else { return }
            if pinch.state == .began {
                // A second finger can arrive during a horizontal pan. Give the
                // pinch a fresh snapshot and cancel the old one-finger gesture.
                pan.isEnabled = false
                // Pinch may coexist with an already-started List pan. Freeze only
                // the List's native scrolling for this pinch; restore on every exit.
                if let scrollView {
                    suspendedScroll = (scrollView, scrollView.isScrollEnabled)
                    scrollView.isScrollEnabled = false
                }
                pinchSnapshot = parent.visible
                gestureWidth = max(1, probe.bounds.width)
                anchor = pinch.location(in: probe).x / gestureWidth
                initialScale = max(0.001, pinch.scale)
            }
            if (pinch.state == .began || pinch.state == .changed), let pinchSnapshot {
                parent.visible = ChartViewport.zoom(pinchSnapshot, in: parent.bounds, scale: pinch.scale / initialScale,
                                                    anchor: anchor, currentAnchor: pinch.location(in: probe).x / gestureWidth)
            }
            if pinch.state == .ended || pinch.state == .cancelled || pinch.state == .failed {
                pinchSnapshot = nil
                pan.isEnabled = true
                restoreListScrolling()
            }
        }

        @objc func panned() {
            guard let probe else { return }
            handlePan(state: pan.state, translation: pan.translation(in: probe).x,
                      width: probe.bounds.width)
        }

        /// Stop on lift: deliberately no velocity projection or deceleration timer.
        /// Apply the final touch position before clearing the begin snapshot. Late
        /// changes after end/cancel cannot move the range or revive an old gesture.
        func handlePan(state: UIGestureRecognizer.State, translation: CGFloat, width: CGFloat) {
            if state == .began {
                panSnapshot = parent.visible
                gestureWidth = max(1, width)
                initialTranslation = translation
            }
            if (state == .changed || state == .ended), let panSnapshot {
                parent.visible = ChartViewport.pan(panSnapshot, in: parent.bounds,
                                                   translation: translation - initialTranslation,
                                                   width: gestureWidth)
            }
            if state == .ended || state == .cancelled || state == .failed { panSnapshot = nil }
        }

        @objc func tapped() {
            guard singleTap.state == .ended, let probe else { return }
            let location = singleTap.location(in: probe)
            guard contains(location) else { return }
            parent.onTap(location.x / max(1, probe.bounds.width))
        }

        @objc func reset() {
            guard doubleTap.state == .ended else { return }
            parent.onReset()
        }
    }
}
