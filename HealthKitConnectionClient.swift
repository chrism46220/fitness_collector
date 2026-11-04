import Foundation
import HealthKit

/// A thin wrapper around ``HKHealthStore`` that makes the manager testable.
/// The production implementation forwards all calls to a real ``HKHealthStore``.
protocol HealthKitConnectionClient {
    /// Returns ``true`` when the device supports HealthKit.
    func isHealthDataAvailable() -> Bool

    /// Queries the current authorization request status for the supplied read types.
    func authorizationRequestStatus(
        for readTypes: Set<HKObjectType>,
        completion: @escaping (HKAuthorizationRequestStatus, Error?) -> Void
    )

    /// Requests read‑only authorization for the supplied types.
    func requestReadAuthorization(
        for readTypes: Set<HKObjectType>,
        completion: @escaping (Bool, Error?) -> Void
    )

    /// Fetches the most recent ``limit`` workouts, newest first.
    func fetchWorkouts(
        limit: Int,
        completion: @escaping ([HKSample]?, Error?) -> Void
    )
}

/// Production implementation that talks directly to ``HKHealthStore``.
final class LiveHealthKitConnectionClient: HealthKitConnectionClient {
    private let healthStore: HKHealthStore

    init(healthStore: HKHealthStore = HKHealthStore()) {
        self.healthStore = healthStore
    }

    func isHealthDataAvailable() -> Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    func authorizationRequestStatus(
        for readTypes: Set<HKObjectType>,
        completion: @escaping (HKAuthorizationRequestStatus, Error?) -> Void
    ) {
        healthStore.getRequestStatusForAuthorization(toShare: [], read: readTypes) { status, error in
            completion(status, error)
        }
    }

    func requestReadAuthorization(
        for readTypes: Set<HKObjectType>,
        completion: @escaping (Bool, Error?) -> Void
    ) {
        healthStore.requestAuthorization(toShare: [], read: readTypes) { success, error in
            completion(success, error)
        }
    }

    func fetchWorkouts(
        limit: Int,
        completion: @escaping ([HKSample]?, Error?) -> Void
    ) {
        let query = HKSampleQuery(
            sampleType: .workoutType(),
            predicate: nil,
            limit: limit,
            sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
        ) { _, samples, error in
            completion(samples, error)
        }
        healthStore.execute(query)
    }
}
