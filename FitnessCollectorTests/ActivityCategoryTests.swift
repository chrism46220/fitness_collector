//
//  ActivityCategoryTests.swift
//  FitnessCollectorTests
//
//  Tests for HealthKit activity-type mapping and overview statistics.
//

import XCTest
import HealthKit
@testable import FitnessCollector

final class ActivityCategoryTests: XCTestCase {

    // MARK: - Mapping

    func testRunningTypesMapToRunning() {
        XCTAssertEqual(ActivityCategory.category(for: .running), .running)
        XCTAssertEqual(ActivityCategory.category(for: .trackAndField), .running)
    }

    func testStrengthTypesMapToLifting() {
        let strengthTypes: [HKWorkoutActivityType] = [
            .traditionalStrengthTraining,
            .functionalStrengthTraining,
            .coreTraining,
            .crossTraining,
            .highIntensityIntervalTraining,
        ]
        for type in strengthTypes {
            XCTAssertEqual(ActivityCategory.category(for: type), .lifting,
                           "\(type) should map to .lifting")
        }
    }

    func testTennisTypesMapToTennis() {
        let racketTypes: [HKWorkoutActivityType] = [
            .tennis, .tableTennis, .badminton, .racquetball, .squash, .pickleball,
        ]
        for type in racketTypes {
            XCTAssertEqual(ActivityCategory.category(for: type), .tennis,
                           "\(type) should map to .tennis")
        }
    }

    func testUnmappedTypesFallBackToOther() {
        // These are real HealthKit types that deliberately have no category.
        XCTAssertEqual(ActivityCategory.category(for: .swimming), .other)
        XCTAssertEqual(ActivityCategory.category(for: .cycling), .other)
        XCTAssertEqual(ActivityCategory.category(for: .yoga), .other)
        XCTAssertEqual(ActivityCategory.category(for: .hiking), .other)
        XCTAssertEqual(ActivityCategory.category(for: .other), .other)
    }

    // Every activity type must resolve to exactly one category: the mapping is
    // total, so no HealthKit workout is ever dropped from the app.
    func testMappingIsTotalAndExclusive() {
        for category in ActivityCategory.allCases {
            for type in category.activityTypes {
                XCTAssertEqual(ActivityCategory.category(for: type), category,
                               "\(type) claimed by \(category) but resolved elsewhere")
            }
        }
    }

    // Categories must not overlap, or filtering would double-count workouts.
    func testCategoryMembershipDoesNotOverlap() {
        var seen = Set<HKWorkoutActivityType>()
        for category in ActivityCategory.allCases where category != .other {
            for type in category.activityTypes {
                XCTAssertFalse(seen.contains(type),
                               "\(type) belongs to more than one category")
                seen.insert(type)
            }
        }
    }

    func testOtherCategoryHasNoExplicitMembers() {
        XCTAssertTrue(ActivityCategory.other.activityTypes.isEmpty,
                      ".other is the fallback bucket and should claim no types")
    }

    // Presentational metadata must be unique per category so the overview tiles
    // are distinguishable.
    func testCategoryMetadataIsUnique() {
        let titles = Set(ActivityCategory.allCases.map(\.title))
        XCTAssertEqual(titles.count, ActivityCategory.allCases.count)

        let symbols = Set(ActivityCategory.allCases.map(\.symbolName))
        XCTAssertEqual(symbols.count, ActivityCategory.allCases.count)
    }

    func testWorkoutTypeConvenienceProperty() {
        let activityType = HKWorkoutActivityType.running
        XCTAssertEqual(activityType.category, .running)
    }
}

final class ActivityStatisticsTests: XCTestCase {

    private func makeRow(
        activityType: HKWorkoutActivityType = .running,
        start: Date = Date(),
        durationMinutes: Double = 30,
        calories: Double? = nil,
        distanceMiles: Double? = nil,
        averageHeartRate: Double? = nil
    ) -> WorkoutRow {
        let workout = HKWorkout(
            activityType: activityType,
            start: start,
            end: start.addingTimeInterval(durationMinutes * 60),
            duration: durationMinutes * 60,
            totalEnergyBurned: nil,
            totalDistance: nil,
            metadata: nil
        )
        return WorkoutRow(
            id: UUID(),
            hkWorkout: workout,
            activityType: activityType,
            start: start,
            durationMinutes: durationMinutes,
            calories: calories,
            distanceMiles: distanceMiles,
            averageHeartRate: averageHeartRate,
            maxHeartRate: nil
        )
    }

    // MARK: - Aggregation

    func testEmptyInputYieldsEmptyStatistics() {
        let stats = ActivityStatistics.make(from: [])
        XCTAssertEqual(stats, .empty)
        XCTAssertTrue(stats.isEmpty)
    }

    func testSumsDurationCaloriesAndDistance() {
        let rows = [
            makeRow(durationMinutes: 30, calories: 300, distanceMiles: 3.0),
            makeRow(durationMinutes: 45, calories: 450, distanceMiles: 5.0),
        ]
        let stats = ActivityStatistics.make(from: rows)

        XCTAssertEqual(stats.workoutCount, 2)
        XCTAssertEqual(stats.totalDurationMinutes, 75, accuracy: 1e-9)
        XCTAssertEqual(stats.totalCalories, 750, accuracy: 1e-9)
        XCTAssertEqual(stats.totalDistanceMiles, 8.0, accuracy: 1e-9)
    }

    // Missing measurements are skipped, never treated as zero-valued readings.
    func testMissingValuesAreSkippedNotZeroed() {
        let rows = [
            makeRow(durationMinutes: 30, calories: 300, distanceMiles: 3.0),
            makeRow(durationMinutes: 20, calories: nil, distanceMiles: nil),
        ]
        let stats = ActivityStatistics.make(from: rows)

        XCTAssertEqual(stats.workoutCount, 2)
        XCTAssertEqual(stats.totalCalories, 300, accuracy: 1e-9)
        XCTAssertEqual(stats.totalDistanceMiles, 3.0, accuracy: 1e-9)
    }

    // If no workout reports heart rate, the average must stay nil rather than
    // being reported as a fabricated 0 bpm.
    func testAverageHeartRateIsNilWhenNeverMeasured() {
        let rows = [makeRow(), makeRow()]
        let stats = ActivityStatistics.make(from: rows)
        XCTAssertNil(stats.averageHeartRate)
    }

    // The average uses only workouts that actually supplied a reading.
    func testAverageHeartRateUsesOnlyMeasuredWorkouts() {
        let rows = [
            makeRow(averageHeartRate: 140),
            makeRow(averageHeartRate: 160),
            makeRow(averageHeartRate: nil),
        ]
        let stats = ActivityStatistics.make(from: rows)
        XCTAssertEqual(stats.averageHeartRate ?? -1, 150, accuracy: 1e-9)
    }

    func testLastWorkoutDateIsMostRecent() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let rows = [
            makeRow(start: base),
            makeRow(start: base.addingTimeInterval(3600)),
            makeRow(start: base.addingTimeInterval(-3600)),
        ]
        let stats = ActivityStatistics.make(from: rows)
        XCTAssertEqual(stats.lastWorkoutDate, base.addingTimeInterval(3600))
    }

    // MARK: - Category filtering

    func testInCategoryFiltersAndSortsNewestFirst() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let rows = [
            makeRow(activityType: .running, start: base),
            makeRow(activityType: .traditionalStrengthTraining,
                    start: base.addingTimeInterval(7200)),
            makeRow(activityType: .running, start: base.addingTimeInterval(3600)),
            makeRow(activityType: .swimming, start: base.addingTimeInterval(100)),
        ]

        let runs = rows.inCategory(.running)
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].start, base.addingTimeInterval(3600))
        XCTAssertEqual(runs[1].start, base)

        let lifting = rows.inCategory(.lifting)
        XCTAssertEqual(lifting.count, 1)

        let other = rows.inCategory(.other)
        XCTAssertEqual(other.count, 1)
        XCTAssertEqual(other.first?.activityType, .swimming)

        XCTAssertTrue(rows.inCategory(.tennis).isEmpty)
    }

    // Every workout lands in exactly one category bucket: no duplicates, no loss.
    func testEveryWorkoutAppearsInExactlyOneCategory() {
        let types: [HKWorkoutActivityType] = [
            .running, .traditionalStrengthTraining, .tennis, .swimming, .cycling, .yoga,
        ]
        let rows = types.map { makeRow(activityType: $0) }

        let bucketed = ActivityCategory.allCases.flatMap { rows.inCategory($0) }
        XCTAssertEqual(bucketed.count, rows.count)

        let ids = bucketed.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "a workout appears in two categories")
    }

    // MARK: - WorkoutRow derived values

    func testCategoryIsDerivedFromActivityType() {
        XCTAssertEqual(makeRow(activityType: .running).category, .running)
        XCTAssertEqual(makeRow(activityType: .traditionalStrengthTraining).category, .lifting)
        XCTAssertEqual(makeRow(activityType: .tennis).category, .tennis)
        XCTAssertEqual(makeRow(activityType: .swimming).category, .other)
    }

    // Pace is only meaningful when a distance was recorded.
    func testAveragePaceRequiresDistance() {
        XCTAssertNil(makeRow(distanceMiles: nil).averagePaceSecondsPerMile)
        XCTAssertNil(makeRow(distanceMiles: 0).averagePaceSecondsPerMile)

        // 30 minutes over 5 miles = 6 min/mile = 360 s/mile
        let paced = makeRow(durationMinutes: 30, distanceMiles: 5.0)
        XCTAssertEqual(paced.averagePaceSecondsPerMile ?? -1, 360, accuracy: 1e-9)
    }
}
