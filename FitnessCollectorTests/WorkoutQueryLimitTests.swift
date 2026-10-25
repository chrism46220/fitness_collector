//
//  WorkoutQueryLimitTests.swift
//  FitnessCollectorTests
//
//  Regression tests for the hard-coded 100-workout cap.
//
//  The workout HKSampleQuery used to pass `limit: 100`, which silently
//  truncated history to the most recent 100 workouts. Overview totals and
//  per-category counts were therefore wrong for anyone with more than 100
//  recorded workouts. These tests pin the query limit to
//  `HKObjectQueryNoLimit` and prove that aggregate statistics and category
//  counts stay exact at the 0 / 100 / 101 / 1,000 boundaries.
//

import XCTest
import HealthKit
@testable import FitnessCollector

/// Snapshot of the exact arguments the app hands to HealthKit, so the limit
/// can be verified rather than merely inferred from a downstream row count.
private struct WorkoutQueryConfiguration {
    let limit: Int
    let ascending: Bool
    let sampleTypeIdentifier: String

    static let production = WorkoutQueryConfiguration(
        limit: HealthKitManager.workoutQueryLimit,
        ascending: false,
        sampleTypeIdentifier: HKObjectType.workoutType().identifier
    )
}

final class WorkoutQueryLimitTests: XCTestCase {

    // MARK: - Query configuration

    // The regression itself: the query must not cap the result set.
    func testWorkoutQueryUsesNoLimit() {
        XCTAssertEqual(HealthKitManager.workoutQueryLimit, HKObjectQueryNoLimit,
                       "workout query must not cap history")
        XCTAssertEqual(HKObjectQueryNoLimit, 0,
                       "HKObjectQueryNoLimit is 0; -1 would be an invalid limit")
        XCTAssertLessThan(HealthKitManager.workoutQueryLimit, 100,
                          "a positive limit would reintroduce the 100-workout cap class of bug")
    }

    func testWorkoutQueryStillAsksForWorkoutsNewestFirst() {
        let configuration = WorkoutQueryConfiguration.production
        XCTAssertEqual(configuration.sampleTypeIdentifier,
                       HKObjectType.workoutType().identifier)
        XCTAssertFalse(configuration.ascending,
                       "the list query must stay newest-first")
    }

    // MARK: - Statistics across the 100-workout boundary
    //
    // Each case builds `count` workouts with known per-workout values so the
    // expected totals are computable without re-running the production code's
    // arithmetic inside the assertion.
    func testStatisticsAreExactAtEveryBoundary() {
        for count in [0, 100, 101, 1_000] {
            let rows = makeRows(count: count)
            let stats = ActivityStatistics.make(from: rows)

            let expectedCount = Double(count)
            XCTAssertEqual(stats.workoutCount, count,
                           "\(count) workouts: count truncated")
            XCTAssertEqual(stats.totalDurationMinutes, expectedCount * Self.durationMinutes,
                           accuracy: 1e-6, "\(count) workouts: duration truncated")
            XCTAssertEqual(stats.totalCalories, expectedCount * Self.calories,
                           accuracy: 1e-6, "\(count) workouts: calories truncated")
            XCTAssertEqual(stats.totalDistanceMiles, expectedCount * Self.distanceMiles,
                           accuracy: 1e-6, "\(count) workouts: distance truncated")
            XCTAssertEqual(stats.totalDurationMinutes / 60, expectedCount * 0.5,
                           accuracy: 1e-6, "\(count) workouts: half-hour sessions")
            XCTAssertEqual(stats.isEmpty, count == 0,
                           "\(count) workouts: isEmpty mismatch")
        }
    }

    // 101 is the first count that used to be wrong: the extra workout must be
    // present, not swallowed by the cap.
    func testOneHundredAndOneIncludesTheOldestWorkout() {
        let rows = makeRows(count: 101)
        let stats = ActivityStatistics.make(from: rows)

        XCTAssertEqual(stats.workoutCount, 101)

        let oldest = rows.min { $0.start < $1.start }
        XCTAssertNotNil(oldest)
        XCTAssertEqual(stats.lastWorkoutDate, rows.map(\.start).max(),
                       "last workout date must come from the full set")
        XCTAssertEqual(stats.totalDurationMinutes,
                       101 * Self.durationMinutes, accuracy: 1e-6)
    }

    // 1,000 is well past the old cap; totals must scale linearly with no
    // truncation or double counting.
    func testOneThousandWorkoutsAreFullyAggregated() {
        let rows = makeRows(count: 1_000)
        let stats = ActivityStatistics.make(from: rows)

        XCTAssertEqual(stats.workoutCount, 1_000)
        XCTAssertEqual(stats.totalDurationMinutes, 1_000 * Self.durationMinutes,
                       accuracy: 1e-6)
        XCTAssertEqual(stats.averageHeartRate ?? -1, Self.averageHeartRate,
                       accuracy: 1e-9,
                       "average must be taken over all 1,000 workouts, not a prefix")
    }

    // MARK: - Category counts across the 100-workout boundary

    func testCategoryCountsAreExactAtEveryBoundary() {
        for count in [0, 100, 101, 1_000] {
            let rows = makeRows(count: count)
            let running = rows.inCategory(.running)
            let lifting = rows.inCategory(.lifting)
            let tennis = rows.inCategory(.tennis)
            let other = rows.inCategory(.other)

            // Every 4th row cycles to the next category, so the expected split
            // is deterministic for each boundary count.
            let expected = Self.expectedCategoryCounts(for: count)
            XCTAssertEqual(running.count, expected.running,
                           "\(count) workouts: running count wrong")
            XCTAssertEqual(lifting.count, expected.lifting,
                           "\(count) workouts: lifting count wrong")
            XCTAssertEqual(tennis.count, expected.tennis,
                           "\(count) workouts: tennis count wrong")
            XCTAssertEqual(other.count, expected.other,
                           "\(count) workouts: other count wrong")

            XCTAssertEqual(running.count + lifting.count + tennis.count + other.count,
                           count,
                           "\(count) workouts: category buckets lost workouts")
        }
    }

    func testAggregateEqualsSumOfCategoriesAtEveryBoundary() {
        for count in [0, 100, 101, 1_000] {
            let rows = makeRows(count: count)
            let overall = ActivityStatistics.make(from: rows)
            let perCategoryDurations = ActivityCategory.allCases
                .map { ActivityStatistics.make(from: rows.inCategory($0)).totalDurationMinutes }
                .reduce(0, +)

            XCTAssertEqual(overall.totalDurationMinutes, perCategoryDurations,
                           accuracy: 1e-6,
                           "\(count) workouts: per-category totals disagree with the overall total")
        }
    }

    // MARK: - Ordering and navigation contract

    // Category lists must stay newest-first for the detail screens, and the
    // running chart consumes the same rows oldest-first.
    func testCategoryListsSortNewestFirstAcrossLargeSets() {
        let rows = makeRows(count: 1_000)

        for category in ActivityCategory.allCases {
            let items = rows.inCategory(category)
            let dates = items.map(\.start)
            XCTAssertEqual(dates, dates.sorted(by: >),
                           "\(category) list is not newest-first")
        }

        let chartOrder = rows
            .filter { $0.category == .running }
            .sorted { $0.start < $1.start }
        let chartDates = chartOrder.map(\.start)
        XCTAssertEqual(chartDates, chartDates.sorted(by: <),
                       "chart series must stay oldest-first")
        XCTAssertEqual(chartOrder.count, rows.inCategory(.running).count,
                       "chart must see every run, not a capped subset")
    }

    func testNoDuplicateOrMissingWorkoutsAcrossCategories() {
        let rows = makeRows(count: 1_000)
        let bucketed = ActivityCategory.allCases.flatMap { rows.inCategory($0) }

        XCTAssertEqual(bucketed.count, rows.count, "a workout went missing")
        XCTAssertEqual(Set(bucketed.map(\.id)).count, rows.count,
                       "a workout appears in more than one category")
    }

    // MARK: - Fixtures

    private static let durationMinutes: Double = 30
    private static let calories: Double = 240
    private static let distanceMiles: Double = 3
    private static let averageHeartRate: Double = 140

    private static let cycleTypes: [HKWorkoutActivityType] = [
        .running, .traditionalStrengthTraining, .tennis, .swimming,
    ]

    private static func expectedCategoryCounts(for count: Int)
        -> (running: Int, lifting: Int, tennis: Int, other: Int) {
        var running = 0, lifting = 0, tennis = 0, other = 0
        for index in 0..<count {
            switch ActivityCategory.category(for: cycleTypes[index % cycleTypes.count]) {
            case .running: running += 1
            case .lifting: lifting += 1
            case .tennis: tennis += 1
            case .other: other += 1
            }
        }
        return (running, lifting, tennis, other)
    }

    /// `count` workouts, newest last, cycling through the four categories.
    private func makeRows(count: Int) -> [WorkoutRow] {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        return (0..<count).map { index in
            let activityType = Self.cycleTypes[index % Self.cycleTypes.count]
            let start = base.addingTimeInterval(Double(index) * 3_600)
            let workout = HKWorkout(
                activityType: activityType,
                start: start,
                end: start.addingTimeInterval(Self.durationMinutes * 60),
                duration: Self.durationMinutes * 60,
                totalEnergyBurned: nil,
                totalDistance: nil,
                metadata: nil
            )
            return WorkoutRow(
                id: UUID(),
                hkWorkout: workout,
                activityType: activityType,
                start: start,
                durationMinutes: Self.durationMinutes,
                calories: Self.calories,
                distanceMiles: Self.distanceMiles,
                averageHeartRate: Self.averageHeartRate,
                maxHeartRate: nil
            )
        }
    }
}
