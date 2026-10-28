//
//  ActivityCategory.swift
//  FitnessCollector
//
//  Maps HealthKit workout activity types onto the app's top-level activity
//  categories. This is the single source of truth for category membership so
//  the navigation hierarchy never has to reason about raw HK types.
//

import Foundation
import HealthKit

/// The four top-level activity buckets shown on the fitness overview.
///
/// `HKWorkoutActivityType` has well over 80 cases and Apple adds more with each
/// OS release, so mapping is expressed as category membership rather than an
/// exhaustive switch. Anything unmapped falls into `.other` rather than being
/// dropped, which keeps HealthKit data visible instead of silently discarding it.
enum ActivityCategory: String, CaseIterable, Identifiable, Sendable {
    case running
    case lifting
    case tennis
    case other

    var id: String { rawValue }

    /// Display name for navigation and section headers.
    var title: String {
        switch self {
        case .running: return "Running"
        case .lifting: return "Lifting"
        case .tennis: return "Tennis"
        case .other: return "Other"
        }
    }

    /// Short label used on overview tiles.
    var subtitle: String {
        switch self {
        case .running: return "Runs, pace, heart rate"
        case .lifting: return "Strength sessions, duration, calories"
        case .tennis: return "Matches, duration, heart rate"
        case .other: return "Walking, cycling, HIIT and more"
        }
    }

    /// SF Symbol used for the category tile.
    var symbolName: String {
        switch self {
        case .running: return "figure.run"
        case .lifting: return "figure.strengthtraining.traditional"
        case .tennis: return "figure.tennis"
        case .other: return "figure.mixed.cardio"
        }
    }

    /// The HealthKit activity types belonging to this category.
    ///
    /// Ordering is not significant; `Other` intentionally has no explicit
    /// members and instead claims every type not listed elsewhere.
    var activityTypes: Set<HKWorkoutActivityType> {
        switch self {
        case .running:
            return [.running, .trackAndField]
        case .lifting:
            return [
                .traditionalStrengthTraining,
                .functionalStrengthTraining,
                .coreTraining,
                .crossTraining,
                .highIntensityIntervalTraining,
            ]
        case .tennis:
            return [.tennis, .tableTennis, .badminton, .racquetball, .squash, .pickleball]
        case .other:
            return []
        }
    }

    /// Resolves the category for a HealthKit activity type.
    ///
    /// Unrecognised types resolve to `.other`; this function is total.
    static func category(for activityType: HKWorkoutActivityType) -> ActivityCategory {
        for category in ActivityCategory.allCases where category != .other {
            if category.activityTypes.contains(activityType) {
                return category
            }
        }
        return .other
    }
}

extension HKWorkoutActivityType {
    /// The app-level category this activity type belongs to.
    var category: ActivityCategory {
        ActivityCategory.category(for: self)
    }
}
