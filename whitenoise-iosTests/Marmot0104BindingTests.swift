import Foundation
import Network
import os
import MarmotKit
import Testing

@testable import whitenoise_ios

@MainActor
@Suite(.serialized)
struct Marmot0104BindingTests {
    @Test func acceptedTokenSurvivesRestartAndRejectsChangedRequests() async throws {
        let relay = try LocalAdmissionTestRelay()
        defer { relay.stop() }
        let relayURL = try await relay.start()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalAdmission-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func openRuntime() throws -> MarmotClient {
            try MarmotClient(
                rootPath: root.path, relayUrls: [relayURL], cursorPersistence: .advance,
                telemetryConfig: .current(), relayPolicy: .allowLoopback)
        }
        let client = try openRuntime()
        let watchdog = Task {
            try await Task.sleep(for: MarmotFixtureWatchdog.deadlineOnlyADeadlockCanReach)
            Issue.record("Durable token test stalled")
            try await client.marmot.shutdownAndClose()
        }
        defer { watchdog.cancel() }
        do {
            try await client.startRuntime()
            let account = try await client.marmot.createIdentityWithProfile(
                defaultRelays: [relayURL], bootstrapRelays: [relayURL]).account
            let group = try await client.createGroupWithOptionsDetailed(accountRef: account.label,
                name: "Local admission", memberRefs: [], options: CreateGroupOptionsFfi(
                    description: nil, initialImage: nil, disappearingMessageSecs: 0))
            let token = UUID().uuidString
            let accepted = try await client.sendTextWithClientToken(accountRef: account.label,
                groupIdHex: group.groupIdHex, text: "Durable message", clientToken: token)
            // Admission only queues the send. Establish engine completion before testing reuse.
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            var status = try await client.localSendStatus(accountRef: account.label,
                groupIdHex: group.groupIdHex, clientToken: token)
            while status == .queued || status == .engineOwned, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(25))
                status = try await client.localSendStatus(accountRef: account.label,
                    groupIdHex: group.groupIdHex, clientToken: token)
            }
            guard case .completed = status else {
                Issue.record("The relay-backed fixture must complete its send before testing token reuse")
                try await client.marmot.shutdownAndClose()
                return
            }
            let repeated = try await client.sendTextWithClientToken(accountRef: account.label,
                groupIdHex: group.groupIdHex, text: "Durable message", clientToken: token)
            #expect(accepted == repeated)
            #expect(accepted.clientToken == token)
            #expect(!accepted.messageIdHex.isEmpty)
            #expect(try await client.localSendStatus(accountRef: account.label,
                groupIdHex: group.groupIdHex, clientToken: token) != nil)
            do {
                _ = try await client.sendTextWithClientToken(accountRef: account.label,
                    groupIdHex: group.groupIdHex, text: "Changed request", clientToken: token)
                Issue.record("A token must not be reassigned to a different request")
            } catch MarmotKitError.Runtime(let details) {
                #expect(details.contains("client token is already bound to another submission"))
            }
            let window = try await client.openConversationWindow(
                accountRef: account.label, groupIdHex: group.groupIdHex)
            let snapshot = try #require(window.snapshot())
            #expect(snapshot.messages.filter { $0.timeline.clientToken == token }.count == 1)
            await window.cancel()
            try await client.marmot.shutdownAndClose()
            let restarted = try openRuntime()
            do {
                let restoredStatus = try await restarted.localSendStatus(accountRef: account.label,
                    groupIdHex: group.groupIdHex, clientToken: token)
                #expect(restoredStatus == status)
                try await restarted.marmot.shutdownAndClose()
            } catch {
                try? await restarted.marmot.shutdownAndClose()
                throw error
            }
        } catch {
            try? await client.marmot.shutdownAndClose()
            throw error
        }
    }

    @Test func offlineTokenRetryPreservesAcceptedOrRejectedStateAcrossRestart() async throws {
        let client = try MarmotClient.testClient()
        let watchdog = MarmotFixtureWatchdog.start("Durable token test stalled", breaking: client)
        defer { watchdog.cancel() }
        do {
            try await client.startRuntime()
            let account = try await client.marmot.createIdentityWithProfile(
                defaultRelays: client.relayUrls, bootstrapRelays: client.relayUrls
            ).account
            let group = try await client.createGroupWithOptionsDetailed(
                accountRef: account.label,
                name: "Local admission", memberRefs: [],
                options: CreateGroupOptionsFfi(
                    description: nil, initialImage: nil, disappearingMessageSecs: 0))
            let token = UUID().uuidString
            let accepted = try await client.sendTextWithClientToken(
                accountRef: account.label,
                groupIdHex: group.groupIdHex, text: "Durable message", clientToken: token)
            var rejectedBeforeRetry = false
            do {
                let repeated = try await client.sendTextWithClientToken(
                    accountRef: account.label,
                    groupIdHex: group.groupIdHex, text: "Durable message", clientToken: token)
                #expect(accepted == repeated)
            } catch MarmotKitError.Runtime(let details) {
                // This offline fixture may reject work before engine acceptance.
                #expect(
                    details
                        == "invalid app message payload: client token belongs to a rejected submission; use a new token"
                )
                let status = try await client.localSendStatus(
                    accountRef: account.label,
                    groupIdHex: group.groupIdHex, clientToken: token)
                guard case .rejected? = status else {
                    Issue.record("A repeated token may fail only after its original submission was rejected")
                    throw MarmotKitError.Runtime(details: details)
                }
                rejectedBeforeRetry = true
            }
            #expect(accepted.clientToken == token)
            #expect(!accepted.messageIdHex.isEmpty)
            #expect(
                try await client.localSendStatus(
                    accountRef: account.label,
                    groupIdHex: group.groupIdHex, clientToken: token) != nil)
            do {
                _ = try await client.sendTextWithClientToken(
                    accountRef: account.label,
                    groupIdHex: group.groupIdHex, text: "Changed request", clientToken: token)
                Issue.record("A token must not be reassigned to a different request")
            } catch MarmotKitError.Runtime(let details) {
                #expect(details.contains("client token is already bound to another submission"))
            }
            let window = try await client.openConversationWindow(
                accountRef: account.label, groupIdHex: group.groupIdHex)
            let snapshot = try #require(window.snapshot())
            let retained = snapshot.messages.filter { $0.timeline.clientToken == token }
            #expect(retained.count <= 1)
            let observedStatus = try await client.localSendStatus(
                accountRef: account.label,
                groupIdHex: group.groupIdHex, clientToken: token)
            if retained.isEmpty {
                // A rejected optimistic row can disappear; an admitted live row cannot.
                guard case .rejected? = observedStatus else {
                    Issue.record("A non-rejected local submission must retain its original timeline row")
                    throw MarmotKitError.Runtime(details: "Missing original local submission row")
                }
            } else {
                #expect(retained.first?.timeline.messageIdHex == accepted.messageIdHex)
            }
            await window.cancel()
            try await client.marmot.shutdownAndClose()
            let restarted = try MarmotClient(rootPath: client.rootPath, relayUrls: client.relayUrls)
            do {
                let status = try await restarted.localSendStatus(
                    accountRef: account.label,
                    groupIdHex: group.groupIdHex, clientToken: token)
                #expect(status != nil)
                if rejectedBeforeRetry {
                    guard case .rejected? = status else {
                        Issue.record("A rejected submission must remain rejected after restart")
                        throw MarmotKitError.Runtime(details: "Rejected local submission changed state")
                    }
                }
                try await restarted.marmot.shutdownAndClose()
            } catch {
                try? await restarted.marmot.shutdownAndClose()
                throw error
            }
        } catch {
            try? await client.marmot.shutdownAndClose()
            throw error
        }
    }

    @Test func attachmentGenerationsRejectStaleAndConsumedPermissions() async throws {
        let client = try MarmotClient.testClient()
        let watchdog = MarmotFixtureWatchdog.start(
            "Attachment permission test stalled", breaking: client)
        defer { watchdog.cancel() }
        do {
            try await client.startRuntime()
            let account = try await client.marmot.createIdentityWithProfile(
                defaultRelays: client.relayUrls, bootstrapRelays: client.relayUrls
            ).account
            let first = try await client.marmot.beginAttachmentPermissionUpdate(accountRef: account.label)
            let second = try await client.marmot.beginAttachmentPermissionUpdate(
                accountRef: account.label)
            let permission = AttachmentAutomaticPermissionFfi(
                images: true, videos: false, audio: false, files: false)
            #expect(
                try await !client.marmot.setAttachmentAutomaticPermission(
                    accountRef: account.label,
                    generation: first, permission: permission))
            #expect(
                try await client.marmot.setAttachmentAutomaticPermission(
                    accountRef: account.label,
                    generation: second, permission: permission))
            #expect(
                try await !client.marmot.setAttachmentAutomaticPermission(
                    accountRef: account.label,
                    generation: second, permission: permission))
            _ = try await client.signOut(accountRef: account.label, deleteKeyPackages: false)
            await #expect(throws: MarmotKitError.AttachmentAccountSignedOut) {
                _ = try await client.marmot.beginAttachmentPermissionUpdate(accountRef: account.label)
            }
            try await client.marmot.shutdownAndClose()
        } catch {
            try? await client.marmot.shutdownAndClose()
            throw error
        }
    }

    @Test func terminalAttachmentStatesDoNotWaitOrRetryAutomatically() {
        #if WN_CURRENT_SDK_API || WN_EXPERIMENTAL_DEVICE_SYNC
        #expect(!AttachmentAcquisitionPresentation.canAwait(.storageBlocked))
        #expect(AttachmentTransferPresentation.label(.storageBlocked) == L10n.string("Waiting to retry"))
        #endif
        for state in [
            AttachmentTransferStateFfi.previouslyAcquiredUnavailable, .completedUnretained,
            .retryExhausted, .removed, .cancelled, .failed, .policyBlocked, .paused, .unavailable,
        ] {
            #expect(!AttachmentAcquisitionPresentation.canAwait(state))
        }
        for state in [AttachmentTransferStateFfi.queued, .downloading, .ready, .retryScheduled] {
            #expect(AttachmentAcquisitionPresentation.canAwait(state))
        }
    }

    @Test func readyAttachmentWaitReadsRetainedBytes() async throws {
        let probe = AttachmentWaitProbe(states: [.queued, .ready])
        let data = try await AttachmentAcquisitionPresentation.awaitRetainedBytes(
            next: { await probe.next() }, read: { await probe.read() })
        #expect(data == Data([1]))
        let counts = await probe.counts()
        #expect(counts.snapshots == 2)
        #expect(counts.reads == 1)
    }

    #if WN_CURRENT_SDK_API || WN_EXPERIMENTAL_DEVICE_SYNC
    @Test func storageBlockedStopsAnAlreadyRunningAttachmentWait() async {
        let probe = AttachmentWaitProbe(states: [.queued, .storageBlocked, .ready])
        do {
            _ = try await AttachmentAcquisitionPresentation.awaitRetainedBytes(
                next: { await probe.next() }, read: { await probe.read() })
            Issue.record("A parked transfer must stop the existing wait before ready bytes can be read")
        } catch AttachmentReadError.unavailable {
            // Expected on the second snapshot, without consuming the later ready frame.
        } catch {
            Issue.record("Expected the bounded unavailable attachment outcome")
        }
        let counts = await probe.counts()
        #expect(counts.snapshots == 2)
        #expect(counts.reads == 0)
    }
    #endif
}

private actor AttachmentWaitProbe {
    private let states: [AttachmentTransferStateFfi]
    private var snapshots = 0
    private var reads = 0

    init(states: [AttachmentTransferStateFfi]) { self.states = states }

    func next() -> AttachmentTransferSnapshotFfi? {
        guard snapshots < states.count else { return nil }
        let state = states[snapshots]
        snapshots += 1
        return AttachmentTransferSnapshotFfi(items: [AttachmentTransferStatusFfi(
            reference: "synthetic-checkpoint", state: state, attempt: 1,
            received: 16, total: 32, retryAt: nil)])
    }

    func read() -> Data? {
        reads += 1
        return Data([1])
    }

    func counts() -> (snapshots: Int, reads: Int) { (snapshots, reads) }
}

/// Isolated relay: empty history and successful publication acknowledgments for the binding fixture.
private nonisolated final class LocalAdmissionTestRelay: Sendable {
    private let queue = DispatchQueue(label: "LocalAdmissionTestRelay")
    private let listener: NWListener
    private let connections = OSAllocatedUnfairLock(initialState: [NWConnection]())

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    guard let port = listener.port else {
                        continuation.resume(throwing: NWError.posix(.EADDRNOTAVAIL))
                        return
                    }
                    continuation.resume(returning: "ws://127.0.0.1:\(port.rawValue)")
                case .waiting(let error), .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [self] connection in
                connections.withLock { $0.append(connection) }
                connection.start(queue: queue)
                receive(on: connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.sync {
            listener.newConnectionHandler = nil
            listener.stateUpdateHandler = nil
            listener.cancel()
            connections.withLock { connections in
                connections.forEach { $0.cancel() }
                connections.removeAll()
            }
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self, error == nil else { return }
            if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
               metadata.opcode == .close {
                connection.cancel()
                return
            }
            if let data, let request = try? JSONSerialization.jsonObject(with: data) as? [Any], request.count > 1 {
                var response: [Any]?
                if request.first as? String == "REQ", let subscriptionID = request[1] as? String {
                    response = ["EOSE", subscriptionID]
                } else if request.first as? String == "EVENT", let event = request[1] as? [String: Any],
                          let eventID = event["id"] as? String {
                    response = ["OK", eventID, true, ""]
                }
                if let response, let data = try? JSONSerialization.data(withJSONObject: response) {
                    let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
                    let context = NWConnection.ContentContext(identifier: "relay response", metadata: [metadata])
                    connection.send(content: data, contentContext: context, completion: .idempotent)
                }
            }
            receive(on: connection)
        }
    }
}
