//
//  FitnessCollectorApp.swift
//  FitnessCollector
//
//  Created by Chris on 4/25/26.
//

import SwiftUI

@main
struct FitnessCollectorApp: App {
    /// Single HealthKit manager for the whole app. Level 1 owns authorization
    /// and loading; activity views observe the same instance rather than each
    /// running their own HealthKit queries.
    @StateObject private var health = HealthKitManager()

    var body: some Scene {
        WindowGroup {
            FitnessOverviewView(health: health)
        }
    }
}
