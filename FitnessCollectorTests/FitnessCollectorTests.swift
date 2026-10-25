//
//  FitnessCollectorTests.swift
//  FitnessCollectorTests
//
//  Phase 1: characterisation tests over the existing chart/pace logic.
//  These validate current behaviour in place. They are written so that the
//  Phase 2 refactor can move the implementations without editing these tests.
//

import XCTest
import HealthKit
@testable import FitnessCollector

final class PaceSmoothingTests: XCTestCase {

    // A constant signal must be preserved exactly by the centred rolling average.
    func testConstantPaceIsUnchanged() {
        let samples = (0..<40).map { i in
            PaceSample(minutesFromStart: Double(i), paceMinutesPerMile: 8.0)
        }
        let manager = HealthKitManager()
        let smoothed = manager.smoothPaceSamples(samples)

        XCTAssertEqual(smoothed.count, samples.count)
        for (index, sample) in smoothed.enumerated() {
            XCTAssertEqual(sample.minutesFromStart, samples[index].minutesFromStart, accuracy: 1e-9)
            XCTAssertEqual(sample.paceMinutesPerMile, 8.0, accuracy: 1e-9)
        }
    }

    // Below the 15-sample threshold the smoothing is a pass-through.
    func testShortInputPassesThrough() {
        let samples = (0..<14).map { i in
            PaceSample(minutesFromStart: Double(i), paceMinutesPerMile: Double(i))
        }
        let manager = HealthKitManager()
        let smoothed = manager.smoothPaceSamples(samples)

        XCTAssertEqual(smoothed.count, samples.count)
        for (index, sample) in smoothed.enumerated() {
            XCTAssertEqual(sample.paceMinutesPerMile,
                           samples[index].paceMinutesPerMile,
                           accuracy: 1e-9)
        }
    }

    // Exactly 15 samples is the boundary where smoothing activates.
    func testFifteenSamplesActivatesSmoothing() {
        var samples = (0..<15).map { i in
            PaceSample(minutesFromStart: Double(i), paceMinutesPerMile: 8.0)
        }
        // Large spike in the middle must be visibly damped.
        samples[7] = PaceSample(minutesFromStart: 7, paceMinutesPerMile: 20.0)

        let manager = HealthKitManager()
        let smoothed = manager.smoothPaceSamples(samples)

        XCTAssertEqual(smoothed.count, 15)
        XCTAssertLessThan(smoothed[7].paceMinutesPerMile, 20.0)
    }

    // A single spike is damped but never fully erased: the window is centred,
    // so a lone outlier is averaged with its neighbours.
    func testSingleSpikeIsAttenuatedNotEliminated() {
        var samples = (0..<100).map { i in
            PaceSample(minutesFromStart: Double(i), paceMinutesPerMile: 8.0)
        }
        samples[50] = PaceSample(minutesFromStart: 50, paceMinutesPerMile: 20.0)

        let manager = HealthKitManager()
        let smoothed = manager.smoothPaceSamples(samples)

        XCTAssertGreaterThan(smoothed[50].paceMinutesPerMile, 8.0)
        XCTAssertLessThan(smoothed[50].paceMinutesPerMile, 20.0)
    }

    // The timestamps (x-axis) must be carried through untouched.
    func testTimestampsArePreserved() {
        let samples = (0..<60).map { i in
            PaceSample(minutesFromStart: Double(i) * 0.25,
                       paceMinutesPerMile: 8.0 + Double(i % 3))
        }
        let manager = HealthKitManager()
        let smoothed = manager.smoothPaceSamples(samples)

        for (index, sample) in smoothed.enumerated() {
            XCTAssertEqual(sample.minutesFromStart,
                           samples[index].minutesFromStart,
                           accuracy: 1e-9)
        }
    }

    // Empty input must not crash.
    func testEmptyInputReturnsEmpty() {
        let manager = HealthKitManager()
        XCTAssertTrue(manager.smoothPaceSamples([]).isEmpty)
    }
}

final class ChartGeometryTests: XCTestCase {

    // MARK: - Helpers

    /// Builds a `WorkoutRow`. `HKWorkout` requires a live initialiser, so a
    /// zero-duration workout is used purely as an opaque payload.
    private func makeRow(start: Date, distanceMiles: Double? = 1.0) -> WorkoutRow {
        let workout = HKWorkout(
            activityType: .running,
            start: start,
            end: start,
            duration: 0,
            totalEnergyBurned: nil,
            totalDistance: nil,
            metadata: nil
        )
        return WorkoutRow(
            id: UUID(),
            hkWorkout: workout,
            activityType: .running,
            start: start,
            durationMinutes: 30,
            calories: nil,
            distanceMiles: distanceMiles,
            averageHeartRate: nil,
            maxHeartRate: nil
        )
    }

    private func makeChart(runs: [WorkoutRow],
                           value: @escaping (WorkoutRow) -> Double?)
        -> RunMetricChart {
        RunMetricChart(
            title: "Test",
            unit: "bpm",
            runs: runs,
            chartRange: .thirty,
            value: value,
            onSelectWorkout: { _ in }
        )
    }

    // MARK: - yDomain

    // With no plottable values the domain is the documented 0...1 fallback.
    func testYDomainEmptyFallback() {
        let chart = makeChart(runs: []) { _ in nil }
        let domain = chart.yDomain()
        XCTAssertEqual(domain.lowerBound, 0, accuracy: 1e-9)
        XCTAssertEqual(domain.upperBound, 1, accuracy: 1e-9)
    }

    // Nil values are skipped; the domain is derived only from finite values.
    func testYDomainIgnoresNilValues() {
        let now = Date()
        let rows = [
            makeRow(start: now),
            makeRow(start: now.addingTimeInterval(1)),
            makeRow(start: now.addingTimeInterval(2)),
        ]
        let chart = makeChart(runs: rows) { row in
            row.distanceMiles == 1.0 && row.id == rows[0].id ? 120 : nil
        }
        let domain = chart.yDomain()
        // Single value 120: range is 0, so padding = max(0, |120|*0.05, 1.0) = 6.0
        XCTAssertEqual(domain.lowerBound, 114, accuracy: 1e-9)
        XCTAssertEqual(domain.upperBound, 126, accuracy: 1e-9)
    }

    // Non-finite values are filtered out before computing the domain.
    func testYDomainFiltersNonFinite() {
        let now = Date()
        let rows = [
            makeRow(start: now),
            makeRow(start: now.addingTimeInterval(1)),
        ]
        let chart = makeChart(runs: rows) { row in
            row.id == rows[0].id ? .infinity : 100
        }
        let domain = chart.yDomain()
        // Single finite value 100: padding = max(0, |100|*0.05, 1.0) = 5.0
        XCTAssertEqual(domain.lowerBound, 95, accuracy: 1e-9)
        XCTAssertEqual(domain.upperBound, 105, accuracy: 1e-9)
    }

    // Lower bound is clamped at zero: pace/bpm values can never go negative.
    func testYDomainLowerBoundClampedAtZero() {
        let now = Date()
        let rows = [
            makeRow(start: now, distanceMiles: 1),
            makeRow(start: now.addingTimeInterval(1), distanceMiles: 1),
        ]
        let chart = makeChart(runs: rows) { row in
            row.id == rows[0].id ? 1.0 : 3.0
        }
        let domain = chart.yDomain()
        XCTAssertGreaterThanOrEqual(domain.lowerBound, 0)
    }

    // Larger ranges get 15% padding.
    func testYDomainPaddingScales() {
        let now = Date()
        let rows = [
            makeRow(start: now),
            makeRow(start: now.addingTimeInterval(1)),
        ]
        let chart = makeChart(runs: rows) { row in
            row.id == rows[0].id ? 100 : 200
        }
        let domain = chart.yDomain()
        // range 100 -> padding max(15, 10, 1) = 15
        XCTAssertEqual(domain.lowerBound, 85, accuracy: 1e-9)
        XCTAssertEqual(domain.upperBound, 215, accuracy: 1e-9)
    }

    // MARK: - yAxisTickValues

    // Default tick count is 4 (matches the view's stored property).
    func testTickCountDefaultsToFour() {
        let now = Date()
        let rows = [makeRow(start: now), makeRow(start: now.addingTimeInterval(1))]
        let chart = makeChart(runs: rows) { row in
            row.id == rows[0].id ? 100 : 200
        }
        XCTAssertEqual(chart.yAxisTickValues().count, 4)
    }

    // Explicit tick counts are honoured.
    func testTickCountIsParameterisable() {
        let chart = makeChart(runs: []) { _ in nil }
        XCTAssertEqual(chart.yAxisTickValues(tickCount: 2).count, 2)
        XCTAssertEqual(chart.yAxisTickValues(tickCount: 5).count, 5)
        XCTAssertEqual(chart.yAxisTickValues(tickCount: 9).count, 9)
    }

    // Ticks are evenly spaced across the domain and span it end to end.
    func testTicksAreEvenlySpacedAcrossDomain() {
        let now = Date()
        let rows = [makeRow(start: now), makeRow(start: now.addingTimeInterval(1))]
        let chart = makeChart(runs: rows) { row in
            row.id == rows[0].id ? 100 : 200
        }
        let domain = chart.yDomain()   // 85...215
        let ticks = chart.yAxisTickValues()

        XCTAssertEqual(ticks.first!, domain.lowerBound, accuracy: 1e-9)
        XCTAssertEqual(ticks.last!, domain.upperBound, accuracy: 1e-9)

        let expectedStep = (domain.upperBound - domain.lowerBound) / 3.0
        for index in 1..<ticks.count {
            XCTAssertEqual(ticks[index] - ticks[index - 1], expectedStep, accuracy: 1e-9)
        }
    }

    // A tick count of 1 degenerates to a single tick at the lower bound.
    func testSingleTickReturnsLowerBound() {
        let now = Date()
        let rows = [makeRow(start: now)]
        let chart = makeChart(runs: rows) { _ in 150 }
        let ticks = chart.yAxisTickValues(tickCount: 1)
        XCTAssertEqual(ticks.count, 1)
        XCTAssertEqual(ticks[0], chart.yDomain().lowerBound, accuracy: 1e-9)
    }

    // MARK: - closestRun

    // Picks the temporally nearest run, in either direction.
    func testClosestRunPicksNearest() {
        let base = Date()
        let rows = [
            makeRow(start: base),
            makeRow(start: base.addingTimeInterval(60)),
            makeRow(start: base.addingTimeInterval(600)),
        ]
        let chart = makeChart(runs: rows) { _ in 100 }

        let probe = base.addingTimeInterval(70)
        XCTAssertEqual(chart.closestRun(to: probe)?.id, rows[1].id)
    }

    // Exact match wins.
    func testClosestRunExactMatch() {
        let base = Date()
        let rows = [
            makeRow(start: base),
            makeRow(start: base.addingTimeInterval(60)),
        ]
        let chart = makeChart(runs: rows) { _ in 100 }
        XCTAssertEqual(chart.closestRun(to: base.addingTimeInterval(60))?.id, rows[1].id)
    }

    // Empty run list yields nil rather than crashing.
    func testClosestRunEmptyReturnsNil() {
        let chart = makeChart(runs: []) { _ in nil }
        XCTAssertNil(chart.closestRun(to: Date()))
    }
}
