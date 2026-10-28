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
    @ViewBuilder let selectionSummary: (WorkoutRow, String, Double?) -> SelectionSummary

    @State private var selectedDate: Date?
    @State private var isScrollEnabled: Bool = false

    private let pointSpacing: CGFloat = 58
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

                    Picker("Scroll", selection: $isScrollEnabled) {
                        Text("Scroll Off").tag(false)
                        Text("Scroll On").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 168)
                }
            }

            GeometryReader { geometry in
                let availablePlotWidth = max(1, geometry.size.width - yAxisWidth - yAxisSpacing)
                let plotWidth = chartWidth(containerWidth: availablePlotWidth)

                HStack(alignment: .top, spacing: yAxisSpacing) {
                    yAxisColumn()

                    if isScrollEnabled {
                        ScrollView(.horizontal, showsIndicators: true) {
                            chartBody(width: plotWidth)
                                .frame(
                                    width: plotWidth,
                                    height: chartHeight
                                )
                        }
                    } else {
                        chartBody(width: availablePlotWidth)
                            .frame(
                                width: availablePlotWidth,
                                height: chartHeight
                            )
                    }
                }
            }
            .frame(height: chartHeight + 20)

            Text(isScrollEnabled ? "Scroll to explore · Tap a \(workoutNoun)" : "Full range shown · Tap a \(workoutNoun)")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let selectedDate,
               let closest = closestWorkout(to: selectedDate) {

                selectionSummary(closest, unit, value(closest))
                    .padding(.top, 6)
            }
        }
        .padding(.vertical, 8)
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
        ChartGeometry.yDomain(workouts, value: value)
    }

    func yAxisTickValues(tickCount: Int? = nil) -> [Double] {
        // Implementation lives in ChartGeometry so it can be unit tested.
        ChartGeometry.tickValues(in: yDomain(), tickCount: tickCount ?? self.yAxisTickCount)
    }

    private func formatAxisTick(_ value: Double) -> String {
        if unit.lowercased().contains("bpm") {
            return String(format: "%.0f", value)
        }

        if unit.lowercased().contains("mile") {
            return String(format: "%.1f", value)
        }

        return String(format: "%.0f", value)
    }

    private func chartBody(width: CGFloat) -> some View {
        Chart {
            ForEach(workouts) { run in
                if let y = value(run) {
                    LineMark(
                        x: .value("Date", run.start),
                        y: .value(unit, y)
                    )
                    .interpolationMethod(.catmullRom)

                    PointMark(
                        x: .value("Date", run.start),
                        y: .value(unit, y)
                    )
                }
            }

            if let selectedDate,
               let selected = closestWorkout(to: selectedDate),
               let y = value(selected) {
                PointMark(
                    x: .value("Selected Date", selected.start),
                    y: .value(unit, y)
                )
                .symbolSize(120)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        SpatialTapGesture()
                            .onEnded { tap in
                                guard let plotFrame = proxy.plotFrame else { return }

                                let x = tap.location.x - geo[plotFrame].origin.x

                                if let date: Date = proxy.value(atX: x),
                                   let closest = closestWorkout(to: date) {
                                    let generator = UIImpactFeedbackGenerator(style: .light)
                                    generator.prepare()
                                    generator.impactOccurred()

                                    selectedDate = closest.start
                                    onSelectWorkout(closest)
                                }
                            }
                    )
            }
        }
        .chartYScale(domain: yDomain())
        .chartYAxis {
            AxisMarks(position: .leading, values: yAxisTickValues()) { _ in
                AxisGridLine()
            }
        }
        .chartXAxis {
            if chartRange == .all {
                AxisMarks(values: .stride(by: .month, count: 1)) { value in
                    AxisGridLine()
                    AxisTick()

                    if let date = value.as(Date.self) {
                        let month = Calendar.current.component(.month, from: date)

                        AxisValueLabel {
                            VStack(spacing: 2) {
                                Text(date.formatted(.dateTime.month(.abbreviated)))

                                if month == 1 {
                                    Text(date.formatted(.dateTime.year()))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            } else {
                AxisMarks()
            }
        }
    }

    private func chartWidth(containerWidth: CGFloat) -> CGFloat {
        guard isScrollEnabled else { return containerWidth }

        let calculated = CGFloat(max(workouts.count, 1)) * pointSpacing
        return max(containerWidth, calculated)
    }

    func closestWorkout(to date: Date) -> WorkoutRow? {
        // Implementation lives in ChartGeometry so it can be unit tested.
        ChartGeometry.closestItem(to: date, in: workouts, timestamp: \.start)
    }

}
