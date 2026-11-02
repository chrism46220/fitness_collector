import Foundation

/// Date-only geometry shared by every metric, independent of missing measurements.
enum ChartViewport {
    static let day: TimeInterval = 86_400

    static func duration(_ range: ClosedRange<Date>) -> TimeInterval {
        range.upperBound.timeIntervalSince(range.lowerBound)
    }

    /// Empty and coincident dates still get a non-degenerate, one-day axis.
    static func bounds(for dates: [Date]) -> ClosedRange<Date> {
        let finite = dates.filter { $0.timeIntervalSinceReferenceDate.isFinite }
        guard let first = finite.min(), let last = finite.max() else {
            return Date(timeIntervalSince1970: 0)...Date(timeIntervalSince1970: day)
        }
        guard last.timeIntervalSince(first) < day else { return first...last }
        let middle = first.addingTimeInterval(last.timeIntervalSince(first) / 2)
        return middle.addingTimeInterval(-day / 2)...middle.addingTimeInterval(day / 2)
    }

    static func clamp(_ range: ClosedRange<Date>, to bounds: ClosedRange<Date>) -> ClosedRange<Date> {
        let total = duration(bounds)
        let span = min(total, max(min(day, total), duration(range)))
        guard span.isFinite, range.lowerBound.timeIntervalSinceReferenceDate.isFinite else { return bounds }
        let start = min(max(range.lowerBound, bounds.lowerBound), bounds.upperBound.addingTimeInterval(-span))
        return start...start.addingTimeInterval(span)
    }

    /// Always derive from a gesture-begin snapshot, never from the previous frame.
    /// Moving the pinch centroid also translates the anchored date naturally.
    static func zoom(_ initial: ClosedRange<Date>, in bounds: ClosedRange<Date>,
                     scale: Double, anchor: Double, currentAnchor: Double? = nil) -> ClosedRange<Date> {
        guard scale.isFinite, scale > 0, anchor.isFinite,
              (currentAnchor ?? anchor).isFinite else { return clamp(initial, to: bounds) }
        let fraction = min(1, max(0, anchor))
        let span = min(duration(bounds), max(min(day, duration(bounds)), duration(initial) / scale))
        let date = initial.lowerBound.addingTimeInterval(duration(initial) * fraction)
        let start = date.addingTimeInterval(-span * (currentAnchor ?? fraction))
        return clamp(start...start.addingTimeInterval(span), to: bounds)
    }

    static func pan(_ initial: ClosedRange<Date>, in bounds: ClosedRange<Date>,
                    translation: Double, width: Double) -> ClosedRange<Date> {
        guard width.isFinite, width > 0, translation.isFinite else { return clamp(initial, to: bounds) }
        let offset = -translation / width * duration(initial)
        return clamp(initial.lowerBound.addingTimeInterval(offset)...initial.upperBound.addingTimeInterval(offset), to: bounds)
    }

    static func isZoomed(_ visible: ClosedRange<Date>, in bounds: ClosedRange<Date>) -> Bool {
        duration(visible) < duration(bounds) - 0.01
    }

    /// Retains the old ~58pt point spacing as a useful initial detail level.
    /// Uses ALL activity dates, so sparse HR charts share exactly the same range.
    static func recentDetail(in bounds: ClosedRange<Date>, dates: [Date], width: Double) -> ClosedRange<Date> {
        guard width.isFinite, width > 0 else { return bounds }
        let unique = Array(Set(dates.filter { bounds.contains($0) })).sorted()
        let capacity = max(2, Int(min(Double(unique.count), width / 58)))
        guard unique.count > capacity else { return bounds }
        let start = unique[unique.count - capacity]
        return clamp(start...bounds.upperBound, to: bounds)
    }
}

/// Identity changes reset the preset; extent changes preserve/clamp a zoomed window.
/// HR enrichment and duplicate-date inserts do not change this identity.
struct ChartViewportContext: Equatable {
    let category: String
    let preset: String
    let extent: ClosedRange<Date>
}

struct ChartViewportState {
    var context: ChartViewportContext
    var visible: ClosedRange<Date>
    var scrollEnabled = false

    init(context: ChartViewportContext) {
        self.context = context
        visible = context.extent
    }

    mutating func reconcile(_ next: ChartViewportContext) {
        guard next != context else { return }
        if next.category != context.category || next.preset != context.preset || !ChartViewport.isZoomed(visible, in: context.extent) {
            visible = next.extent
            scrollEnabled = false
        } else {
            visible = ChartViewport.clamp(visible, to: next.extent)
        }
        context = next
        if !ChartViewport.isZoomed(visible, in: next.extent) { scrollEnabled = false }
    }

    mutating func reset() {
        visible = context.extent
        scrollEnabled = false
    }
}

/// Bounded, width-aware labels, centered in equally sized cells to avoid edge collisions.
enum ChartDateAxis {
    struct Tick: Equatable {
        let date: Date
        let label: String
    }

    static func ticks(in range: ClosedRange<Date>, width: Double,
                      calendar: Calendar = .current, locale: Locale = .current) -> [Tick] {
        guard width.isFinite, width > 0 else { return [] }
        let count = max(1, Int(min(6, width / 88)))
        let step = ChartViewport.duration(range) / Double(count)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        if step >= 366 * ChartViewport.day {
            formatter.dateFormat = "yyyy"
        } else if step >= 31 * ChartViewport.day {
            formatter.setLocalizedDateFormatFromTemplate("MMM")
            formatter.dateFormat += "\nyyyy"
        } else if step >= ChartViewport.day {
            formatter.setLocalizedDateFormatFromTemplate("MMMd")
            formatter.dateFormat += "\nyyyy"
        } else {
            formatter.setLocalizedDateFormatFromTemplate("HHmm")
            formatter.dateFormat += "\nMMM d, yyyy"
        }
        return (0..<count).map { index in
            let date = range.lowerBound.addingTimeInterval((Double(index) + 0.5) * step)
            return Tick(date: date, label: formatter.string(from: date))
        }
    }
}

/// Kept pure so directional arbitration can be tested without synthesizing touches.
enum ChartGesturePolicy {
    static func acceptsPan(zoomed: Bool, x: Double, y: Double) -> Bool {
        zoomed && x.isFinite && y.isFinite && abs(x) > abs(y) * 1.2
    }
}
