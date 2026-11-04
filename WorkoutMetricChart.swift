import SwiftUI
import Charts

struct WorkoutMetricChart<SelectionSummary: View>: View {
    let title: String
    let unit: String
    let workouts: [WorkoutRow]
    let chartRange: ChartRange
    let value: (WorkoutRow) -> Double?
    let onSelectWorkout: (WorkoutRow) -> Void
    let workoutNoun: String
    let activityDates: [Date]
    let fullDateRange: ClosedRange<Date>
    @Binding var visibleDateRange: ClosedRange<Date>
    @Binding var isScrollEnabled: Bool
    var interactionID = ""
    var emptyMessage: String? = nil
    @ViewBuilder let selectionSummary: (WorkoutRow, String, Double?) -> SelectionSummary

    @State private var selectedWorkoutID: UUID?
    @State private var measuredPlotWidth: CGFloat?

    private let chartHeight: CGFloat = 220
    private let yAxisWidth: CGFloat = 42
    private let yAxisSpacing: CGFloat = 6
    private let yAxisTickCount = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                    Text(unit.uppercased())
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(Capsule())
                }

                HStack {
                    Spacer()

                    Picker("Scroll", selection: Binding(get: { isScrollEnabled }, set: { enabled in
                        isScrollEnabled = enabled
                        visibleDateRange = enabled
                            ? ChartViewport.recentDetail(in: fullDateRange, dates: activityDates, width: measuredPlotWidth ?? 280)
                            : fullDateRange
                    })) {
                        Text("Scroll Off").tag(false)
                        Text("Scroll On").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 168)
                }
            }

            GeometryReader { geometry in
                let availablePlotWidth = max(1, geometry.size.width - yAxisWidth - yAxisSpacing)

                HStack(alignment: .top, spacing: yAxisSpacing) {
                    yAxisColumn()
                        .opacity(emptyMessage != nil && visibleWorkouts.isEmpty ? 0 : 1)
                    chartBody(width: availablePlotWidth)
                        .frame(width: availablePlotWidth, height: chartHeight)
                }
            }
            .frame(height: chartHeight + 20)

            Text(ChartViewport.isZoomed(visibleDateRange, in: fullDateRange)
                 ? "Pinch to zoom · Drag to explore · Double-tap to reset"
                 : "Full range · Pinch to zoom · Tap a \(workoutNoun)")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let selected = selectedWorkout {
                selectionSummary(selected, unit, value(selected))
                    .padding(.top, 6)
            }
        }
        .padding(.vertical, 8)
        .onChange(of: chartRange) { _, _ in selectedWorkoutID = nil }
        .onChange(of: visibleDateRange) { _, _ in
            if selectedWorkout == nil { selectedWorkoutID = nil }
        }
    }

    private var visibleWorkouts: [WorkoutRow] {
        ChartGeometry.visibleItems(workouts, in: visibleDateRange, timestamp: \.start, value: value)
            .sorted { $0.start < $1.start }
    }

    private var selectedWorkout: WorkoutRow? {
        visibleWorkouts.first { $0.id == selectedWorkoutID }
    }

    private func yAxisColumn() -> some View {
        let ticks = yAxisTickValues().reversed()

        return VStack(spacing: 0) {
            ForEach(Array(ticks.enumerated()), id: \.element) { index, tick in
                Text(formatAxisTick(tick))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)

                if index < yAxisTickCount - 1 {
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(width: yAxisWidth, height: chartHeight)
        // These roughly match Swift Charts' internal plot-area inset so the
        // fixed labels line up with the visible horizontal gridlines.
        .padding(.top, 8)
        .padding(.bottom, 30)
    }

    func yDomain() -> ClosedRange<Double> {
        // Implementation lives in ChartGeometry so it can be unit tested.
        ChartGeometry.yDomain(visibleWorkouts, value: value)
    }

    func yAxisTickValues(tickCount: Int? = nil) -> [Double] {
        // Implementation lives in ChartGeometry so it can be unit tested.
        ChartGeometry.tickValues(in: yDomain(), tickCount: tickCount ?? self.yAxisTickCount)
    }

    func formatAxisTick(_ value: Double) -> String {
        if unit.lowercased().contains("bpm") {
            return String(format: "%.0f", value)
        }

        if unit.lowercased().contains("mile") || unit == "Minutes" {
            return String(format: "%.1f", value)
        }

        if unit.lowercased() == "min/mi" {
            // guard against non‑finite or overflow values
            if value.isFinite && value >= 0 && value < Double(Int.max) {
                return formatPace(value)
            } else {
                return "—"
            }
        }

        return String(format: "%.0f", value)
    }

    private func chartBody(width: CGFloat) -> some View {
        Chart {
            ForEach(visibleWorkouts) { workout in
                if let y = value(workout) {
                    LineMark(x: .value("Date", workout.start), y: .value(unit, y))
                        .interpolationMethod(.catmullRom)
                    PointMark(x: .value("Date", workout.start), y: .value(unit, y))
                }
            }
            if let selected = selectedWorkout, let y = value(selected) {
                PointMark(x: .value("Selected Date", selected.start), y: .value(unit, y))
                    .symbolSize(120)
            }
        }
        .chartXScale(domain: visibleDateRange, range: .plotDimension(padding: 0))
        .chartYScale(domain: yDomain())
        .chartPlotStyle { plot in
            plot.clipped()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measuredPlotWidth = $0 }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                if visibleWorkouts.isEmpty, let emptyMessage {
                    Text(emptyMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                }
                if let plotFrame = proxy.plotFrame {
                    let frame = geo[plotFrame]
                    ChartPlotGestures(
                        visible: $visibleDateRange, bounds: fullDateRange, interactionID: interactionID,
                        onReset: {
                            selectedWorkoutID = nil
                            isScrollEnabled = false
                            visibleDateRange = fullDateRange
                        },
                        onTap: { fraction in
                            let date = visibleDateRange.lowerBound.addingTimeInterval(
                                fraction * ChartViewport.duration(visibleDateRange))
                            guard let closest = closestWorkout(to: date) else { return }
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            selectedWorkoutID = closest.id
                            onSelectWorkout(closest)
                        }
                    )
                    .allowsHitTesting(false)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: yAxisTickValues()) { _ in AxisGridLine() }
        }
        .chartXAxis {
            let plotWidth = measuredPlotWidth ?? width
            let ticks = ChartDateAxis.ticks(in: visibleDateRange, width: plotWidth)
            AxisMarks(values: ticks.map(\.date)) { axis in
                AxisGridLine()
                AxisTick()
                if let date = axis.as(Date.self), let tick = ticks.first(where: { $0.date == date }) {
                    AxisValueLabel(centered: false) {
                        Text(tick.label)
                            .font(.caption2)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.65)
                            .frame(width: max(1, min(84, plotWidth / CGFloat(max(1, ticks.count)) - 4)))
                    }
                }
            }
        }
    }

    func closestWorkout(to date: Date) -> WorkoutRow? {
        ChartGeometry.closestItem(to: date, in: visibleWorkouts, timestamp: \.start)
    }
}
