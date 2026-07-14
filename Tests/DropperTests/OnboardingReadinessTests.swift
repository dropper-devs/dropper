import Foundation
import XCTest
@testable import Dropper

final class OnboardingReadinessTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        struct Snapshot {
            let verifies: Int
            let accountLoads: Int
            let bucketCreates: Int
            let domainEnables: Int
            let probes: Int
            let probeFinishes: Int
            let persistAttempts: Int
            let persistedToken: String?
            let persistedAccount: String?
            let configured: Int
        }

        private let lock = NSLock()
        private var verifies = 0
        private var accountLoads = 0
        private var bucketCreates = 0
        private var domainEnables = 0
        private var probes = 0
        private var probeFinishes = 0
        private var persistAttempts = 0
        private var persistedToken: String?
        private var persistedAccount: String?
        private var configured = 0
        private let failuresBeforeProbeSuccess: Int

        init(failuresBeforeProbeSuccess: Int = 0) {
            self.failuresBeforeProbeSuccess = failuresBeforeProbeSuccess
        }

        func recordVerify() { update { verifies += 1 } }
        func recordAccounts() { update { accountLoads += 1 } }
        func recordBucket() { update { bucketCreates += 1 } }
        func recordDomain() { update { domainEnables += 1 } }
        func recordProbeFinish() { update { probeFinishes += 1 } }
        func recordConfigured() { update { configured += 1 } }

        func probe() throws {
            let shouldFail = readUpdate {
                probes += 1
                return probes <= failuresBeforeProbeSuccess
            }
            if shouldFail { throw URLError(.secureConnectionFailed) }
        }

        func persist(_ configuration: OnboardingConfiguration) {
            update {
                persistAttempts += 1
                persistedToken = configuration.token
                persistedAccount = configuration.accountID
            }
        }

        func recordPersistAttempt() { update { persistAttempts += 1 } }

        func snapshot() -> Snapshot {
            read {
                Snapshot(
                    verifies: verifies,
                    accountLoads: accountLoads,
                    bucketCreates: bucketCreates,
                    domainEnables: domainEnables,
                    probes: probes,
                    probeFinishes: probeFinishes,
                    persistAttempts: persistAttempts,
                    persistedToken: persistedToken,
                    persistedAccount: persistedAccount,
                    configured: configured)
            }
        }

        private func update(_ body: () -> Void) {
            lock.lock()
            defer { lock.unlock() }
            body()
        }

        private func read<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }

        private func readUpdate<T>(_ body: () -> T) -> T {
            read(body)
        }
    }

    private func dependencies(
        recorder: Recorder,
        verifyToken: ((String) async throws -> String)? = nil,
        probe: (() async throws -> Void)? = nil,
        persistError: Error? = nil
    ) -> OnboardingDependencies {
        OnboardingDependencies(
            verifyToken: verifyToken ?? { _ in
                recorder.recordVerify()
                return "token-id"
            },
            accounts: { _ in
                recorder.recordAccounts()
                return [CloudflareAPI.Account(id: "account-id", name: "Test")]
            },
            createBucket: { _, _, _ in recorder.recordBucket() },
            enablePublicURL: { _, _, _ in
                recorder.recordDomain()
                return "pub-test.r2.dev"
            },
            makeReadinessProbe: { _ in
                OnboardingReadinessProbe(
                    run: probe ?? { try recorder.probe() },
                    finish: { recorder.recordProbeFinish() })
            },
            persist: { configuration in
                if let persistError {
                    recorder.recordPersistAttempt()
                    throw persistError
                }
                recorder.persist(configuration)
            })
    }

    private func waiter(delays: [Duration] = [.zero, .zero]) -> R2ReadinessWaiter {
        R2ReadinessWaiter(retryDelays: delays, sleep: { _ in })
    }

    @MainActor
    func testConfigurationPersistsOnlyAfterReadinessSucceeds() async {
        let recorder = Recorder()
        let model = OnboardingModel(
            dependencies: dependencies(recorder: recorder),
            readinessWaiter: waiter())
        model.token = "secret-token"

        model.connect { recorder.recordConfigured() }
        await model.waitForCurrentOperation()

        let result = recorder.snapshot()
        XCTAssertEqual(model.phase, .done)
        XCTAssertEqual(result.verifies, 1)
        XCTAssertEqual(result.accountLoads, 1)
        XCTAssertEqual(result.bucketCreates, 1)
        XCTAssertEqual(result.domainEnables, 1)
        XCTAssertEqual(result.probes, 1)
        XCTAssertEqual(result.probeFinishes, 1)
        XCTAssertEqual(result.persistAttempts, 1)
        XCTAssertEqual(result.persistedToken, "secret-token")
        XCTAssertEqual(result.persistedAccount, "account-id")
        XCTAssertEqual(result.configured, 1)
        XCTAssertTrue(model.token.isEmpty)
    }

    @MainActor
    func testManualConnectionRetryDoesNotRepeatProvisioning() async {
        let recorder = Recorder(failuresBeforeProbeSuccess: 3)
        let model = OnboardingModel(
            dependencies: dependencies(recorder: recorder),
            readinessWaiter: waiter())
        model.token = "secret-token"

        model.connect { recorder.recordConfigured() }
        await model.waitForCurrentOperation()

        var result = recorder.snapshot()
        XCTAssertEqual(model.phase, .storageNotReady)
        XCTAssertEqual(result.probes, 3)
        XCTAssertEqual(result.persistAttempts, 0)
        XCTAssertEqual(result.configured, 0)
        XCTAssertEqual(model.token, "secret-token")
        XCTAssertEqual(model.submitTitle, "Try Connection Again")

        model.submit { recorder.recordConfigured() }
        await model.waitForCurrentOperation()

        result = recorder.snapshot()
        XCTAssertEqual(model.phase, .done)
        XCTAssertEqual(result.verifies, 1)
        XCTAssertEqual(result.accountLoads, 1)
        XCTAssertEqual(result.bucketCreates, 1)
        XCTAssertEqual(result.domainEnables, 1)
        XCTAssertEqual(result.probes, 4)
        XCTAssertEqual(result.probeFinishes, 2)
        XCTAssertEqual(result.persistAttempts, 1)
        XCTAssertEqual(result.configured, 1)
    }

    @MainActor
    func testNonRetryableReadinessFailureDoesNotPersist() async {
        let recorder = Recorder()
        let model = OnboardingModel(
            dependencies: dependencies(
                recorder: recorder,
                probe: { throw R2Client.R2Error.badStatus(403, "AccessDenied") }),
            readinessWaiter: waiter())
        model.token = "secret-token"

        model.connect { recorder.recordConfigured() }
        await model.waitForCurrentOperation()

        let result = recorder.snapshot()
        guard case .failed = model.phase else {
            return XCTFail("Expected setup to fail")
        }
        XCTAssertEqual(result.probes, 0)
        XCTAssertEqual(result.persistAttempts, 0)
        XCTAssertEqual(result.configured, 0)
        XCTAssertEqual(result.probeFinishes, 1)
    }

    @MainActor
    func testPersistenceFailureCannotReportSetupComplete() async {
        let recorder = Recorder()
        let model = OnboardingModel(
            dependencies: dependencies(
                recorder: recorder,
                persistError: OnboardingPersistenceError.keychain),
            readinessWaiter: waiter())
        model.token = "secret-token"

        model.connect { recorder.recordConfigured() }
        await model.waitForCurrentOperation()

        let result = recorder.snapshot()
        guard case let .failed(message) = model.phase else {
            return XCTFail("Expected persistence to fail")
        }
        XCTAssertTrue(message.contains("Keychain"))
        XCTAssertTrue(model.failureHelp?.contains("Keychain") == true)
        XCTAssertEqual(result.persistAttempts, 1)
        XCTAssertEqual(result.configured, 0)
    }

    @MainActor
    func testCancellationDuringProbeCannotSaveConfiguration() async {
        let recorder = Recorder()
        let probeStarted = expectation(description: "Readiness probe started")
        let model = OnboardingModel(
            dependencies: dependencies(
                recorder: recorder,
                probe: {
                    probeStarted.fulfill()
                    try await Task<Never, Never>.sleep(for: .seconds(60))
                }),
            readinessWaiter: waiter())
        model.token = "secret-token"

        model.connect { recorder.recordConfigured() }
        await fulfillment(of: [probeStarted], timeout: 1)
        model.cancel()
        await model.waitForCurrentOperation()

        let result = recorder.snapshot()
        XCTAssertEqual(result.persistAttempts, 0)
        XCTAssertEqual(result.configured, 0)
        XCTAssertEqual(result.probeFinishes, 1)
        XCTAssertTrue(model.token.isEmpty)
    }

    @MainActor
    func testURLSessionCancellationDuringRESTDoesNotBecomeASetupError() async {
        let recorder = Recorder()
        let model = OnboardingModel(
            dependencies: dependencies(
                recorder: recorder,
                verifyToken: { _ in throw URLError(.cancelled) }),
            readinessWaiter: waiter())
        model.token = "secret-token"

        model.connect { recorder.recordConfigured() }
        await model.waitForCurrentOperation()

        let result = recorder.snapshot()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(result.persistAttempts, 0)
        XCTAssertEqual(result.configured, 0)
    }
}
