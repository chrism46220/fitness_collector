import XCTest
import HealthKit
@testable import FitnessCollector

@MainActor
final class HealthConnectionTests: XCTestCase {
    private final class Client: HealthKitConnectionClient {
        var available = true
        var status: HKAuthorizationRequestStatus = .unnecessary
        var statusError: Error?
        var requestCompleted = true
        var requestError: Error?
        var samples: [HKSample]? = []
        var queryError: Error?
        var statusCalls = 0
        var requestCalls = 0
        var queryCalls = 0
        var queryLimit: Int?
        var statusReadTypes: Set<HKObjectType> = []
        var requestReadTypes: Set<HKObjectType> = []
        var holdStatus = false
        var holdQuery = false
        var pendingStatus: ((HKAuthorizationRequestStatus, Error?) -> Void)?
        var pendingQuery: (([HKSample]?, Error?) -> Void)?
        func isHealthDataAvailable() -> Bool { available }
        func authorizationRequestStatus(for types: Set<HKObjectType>, completion: @escaping (HKAuthorizationRequestStatus, Error?) -> Void) {
            statusCalls += 1
            statusReadTypes = types
            if holdStatus { pendingStatus = completion } else { completion(status, statusError) }
        }
        func requestReadAuthorization(for types: Set<HKObjectType>, completion: @escaping (Bool, Error?) -> Void) {
            requestCalls += 1
            requestReadTypes = types
            completion(requestCompleted, requestError)
        }
        func fetchWorkouts(limit: Int, completion: @escaping ([HKSample]?, Error?) -> Void) {
            queryCalls += 1
            queryLimit = limit
            if holdQuery { pendingQuery = completion } else { completion(samples, queryError) }
        }
    }
    private func turn() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
    private func settle(_ manager: HealthKitManager) async {
        for _ in 0..<30 {
            if !manager.isLoading { return }
            await turn()
        }
        XCTFail("Connection failed to release in-flight state")
    }
    private var failure: NSError { NSError(domain: "ConnectionRegression", code: 7, userInfo: [NSLocalizedDescriptionKey: "test-only diagnostic"]) }

    func testReturningUserAutomaticallyLoadsAfterManagerRecreation() async {
        let client = Client()
        let first = HealthKitManager(connectionClient: client)
        XCTAssertFalse(first.hasRequestedAccess)
        first.refreshIfConnected()
        await settle(first)
        XCTAssertTrue(first.hasRequestedAccess)
        XCTAssertEqual(client.queryCalls, 1)
        let reopened = HealthKitManager(connectionClient: client)
        XCTAssertFalse(reopened.hasRequestedAccess)
        reopened.refreshIfConnected()
        await settle(reopened)
        XCTAssertEqual(client.queryCalls, 2)
        XCTAssertEqual(client.requestCalls, 0)
        XCTAssertTrue(reopened.hasRequestedAccess)
        XCTAssertEqual(client.queryLimit, HKObjectQueryNoLimit)
    }
    func testFirstLaunchDoesNotPresentAuthorizationOrQueryAutomatically() async {
        let client = Client(); client.status = .shouldRequest
        let manager = HealthKitManager(connectionClient: client)
        manager.refreshIfConnected()
        await settle(manager)
        XCTAssertFalse(manager.hasRequestedAccess)
        XCTAssertEqual(client.requestCalls, 0)
        XCTAssertEqual(client.queryCalls, 0)
        XCTAssertTrue(manager.statusMessage.contains("Connect"))
    }
    func testExplicitSetupLoadsThenNextProcessDiscoversCompletedSetup() async {
        let client = Client(); client.status = .shouldRequest
        let manager = HealthKitManager(connectionClient: client)
        manager.requestAccessAndLoadWorkouts()
        await settle(manager)
        XCTAssertEqual(client.requestCalls, 1)
        XCTAssertEqual(client.queryCalls, 1)
        XCTAssertTrue(manager.hasRequestedAccess)
        client.status = .unnecessary
        let next = HealthKitManager(connectionClient: client)
        next.refreshIfConnected()
        await settle(next)
        XCTAssertEqual(client.requestCalls, 1)
        XCTAssertEqual(client.queryCalls, 2)
    }
    func testOverlappingLifecycleAndExplicitCallsCoalesceThroughQueryCompletion() async {
        let client = Client(); client.holdStatus = true; client.holdQuery = true
        let manager = HealthKitManager(connectionClient: client)
        manager.refreshIfConnected()
        manager.refreshIfConnected()
        manager.requestAccessAndLoadWorkouts()
        XCTAssertEqual(client.statusCalls, 1)
        XCTAssertEqual(client.requestCalls, 0)
        client.pendingStatus?(.unnecessary, nil)
        await turn(); await turn()
        XCTAssertEqual(client.queryCalls, 1)
        XCTAssertTrue(manager.isLoading)
        manager.refreshIfConnected()
        XCTAssertEqual(client.statusCalls, 1)
        client.pendingQuery?([], nil)
        await settle(manager)
        client.holdStatus = false; client.holdQuery = false
        manager.refreshIfConnected()
        await settle(manager)
        XCTAssertEqual(client.queryCalls, 2)
    }
    func testStatusErrorReleasesGateAndCanRetry() async {
        let client = Client(); client.statusError = failure
        let manager = HealthKitManager(connectionClient: client)
        manager.refreshIfConnected(); await settle(manager)
        XCTAssertNotNil(manager.diagnosticMessage)
        XCTAssertEqual(client.queryCalls, 0)
        XCTAssertEqual(client.requestCalls, 0)
        client.statusError = nil
        manager.refreshIfConnected(); await settle(manager)
        XCTAssertEqual(client.queryCalls, 1)
        XCTAssertNil(manager.diagnosticMessage)
    }
    func testUnknownStatusDoesNotInferPermissionAndCanRetry() async {
        let client = Client(); client.status = .unknown
        let manager = HealthKitManager(connectionClient: client)
        manager.refreshIfConnected(); await settle(manager)
        XCTAssertFalse(manager.hasRequestedAccess)
        XCTAssertEqual(client.queryCalls, 0)
        XCTAssertEqual(client.requestCalls, 0)
        client.status = .unnecessary
        manager.refreshIfConnected(); await settle(manager)
        XCTAssertEqual(client.queryCalls, 1)
    }
    func testUnavailableDeviceDoesNotStartOperationsOrWedge() async {
        let client = Client(); client.available = false
        let manager = HealthKitManager(connectionClient: client)
        manager.refreshIfConnected()
        manager.requestAccessAndLoadWorkouts()
        XCTAssertFalse(manager.isLoading)
        XCTAssertEqual(client.statusCalls, 0)
        XCTAssertEqual(client.requestCalls, 0)
        client.available = true
        manager.refreshIfConnected(); await settle(manager)
        XCTAssertEqual(client.queryCalls, 1)
    }
    func testCancelledAndFailedSetupCanBeRetriedWithoutClaimingGrant() async {
        let client = Client(); client.requestCompleted = false
        let manager = HealthKitManager(connectionClient: client)
        manager.requestAccessAndLoadWorkouts(); await settle(manager)
        XCTAssertFalse(manager.hasRequestedAccess)
        XCTAssertEqual(client.queryCalls, 0)
        client.requestError = failure
        manager.requestAccessAndLoadWorkouts(); await settle(manager)
        XCTAssertFalse(manager.hasRequestedAccess)
        XCTAssertNotNil(manager.diagnosticMessage)
        client.requestError = nil; client.requestCompleted = true
        manager.requestAccessAndLoadWorkouts(); await settle(manager)
        XCTAssertEqual(client.requestCalls, 3)
        XCTAssertEqual(client.queryCalls, 1)
    }
    func testEmptyReadsAreNotPresentedAsProofOfReadPermission() async {
        let client = Client()
        let manager = HealthKitManager(connectionClient: client)
        manager.refreshIfConnected(); await settle(manager)
        XCTAssertTrue(manager.hasRequestedAccess) // Decision completed, not granted.
        XCTAssertTrue(manager.workouts.isEmpty)
        XCTAssertTrue(manager.statusMessage.contains("read access"))
        XCTAssertFalse(manager.statusMessage.lowercased().contains("granted"))
        XCTAssertEqual(client.requestCalls, 0)
    }
    func testNilQueryAndQueryErrorKeepDiagnosticsAndCanRetry() async {
        let client = Client(); client.samples = nil
        let manager = HealthKitManager(connectionClient: client)
        manager.refreshIfConnected(); await settle(manager)
        XCTAssertNotNil(manager.diagnosticMessage)
        client.queryError = failure
        manager.refreshIfConnected(); await settle(manager)
        XCTAssertEqual(manager.diagnosticMessage, "test-only diagnostic")
        XCTAssertFalse(manager.statusMessage.contains("test-only diagnostic"))
        client.queryError = nil; client.samples = []
        manager.refreshIfConnected(); await settle(manager)
        XCTAssertNil(manager.diagnosticMessage)
        XCTAssertEqual(client.queryCalls, 3)
    }
    func testDiscoveryAndExplicitSetupUseIdenticalReadTypes() async {
        let client = Client(); client.status = .shouldRequest
        let manager = HealthKitManager(connectionClient: client)
        manager.refreshIfConnected(); await settle(manager)
        manager.requestAccessAndLoadWorkouts(); await settle(manager)
        XCTAssertEqual(client.statusReadTypes, client.requestReadTypes)
        XCTAssertTrue(client.statusReadTypes.contains(.workoutType()))
        XCTAssertTrue(client.statusReadTypes.contains(HKSeriesType.workoutRoute()))
        XCTAssertTrue(client.statusReadTypes.contains(HKQuantityType(.heartRate)))
    }
}
