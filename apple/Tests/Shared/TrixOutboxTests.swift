import Foundation
import XCTest
@testable import Trix

@MainActor
final class TrixOutboxTests: XCTestCase {
    private static let dmRoomID = "!dm-alice:trix.selfhost.ru"

    func testOutboxStoreRoundtripUpdateAndRemove() throws {
        let accountJID = "@outbox-\(UUID().uuidString):trix.selfhost.ru"
        let directoryName = "OutboxStoreTests-\(UUID().uuidString)"
        let store = Self.makeOutboxStore(directoryName: directoryName)
        defer {
            try? store.clear(accountJID: accountJID)
            try? FileManager.default.removeItem(at: trixOutboxTestRootURL(directoryName: directoryName))
        }

        let first = TrixOutboxMessage(
            id: "trix-outbox-first",
            roomID: Self.dmRoomID,
            body: "first queued",
            createdAt: Date(timeIntervalSince1970: 100),
            attemptCount: 1
        )
        let second = TrixOutboxMessage(
            id: "trix-outbox-second",
            roomID: Self.dmRoomID,
            body: "second queued",
            createdAt: Date(timeIntervalSince1970: 200),
            attemptCount: 1
        )
        try store.append(second, accountJID: accountJID)
        try store.append(first, accountJID: accountJID)

        let loaded = try store.load(accountJID: accountJID)
        XCTAssertEqual(loaded.map(\.id), ["trix-outbox-first", "trix-outbox-second"])
        XCTAssertEqual(loaded.first?.body, "first queued")

        try store.update(first.registeringFailedAttempt(), accountJID: accountJID)
        let updated = try store.load(accountJID: accountJID)
        XCTAssertEqual(updated.first?.attemptCount, 2)
        XCTAssertEqual(updated.first?.isFailed, false)

        try store.remove(id: first.id, accountJID: accountJID)
        XCTAssertEqual(try store.load(accountJID: accountJID).map(\.id), ["trix-outbox-second"])
    }

    func testOutboxMessageFailsAfterMaxAttempts() {
        var message = TrixOutboxMessage(roomID: Self.dmRoomID, body: "retry me", attemptCount: 1)
        for _ in 0..<3 {
            message = message.registeringFailedAttempt()
            XCTAssertFalse(message.isFailed)
        }

        message = message.registeringFailedAttempt()
        XCTAssertEqual(message.attemptCount, TrixSendRetryPolicy.maxSendAttempts)
        XCTAssertTrue(message.isFailed)

        let retried = message.resetForRetry()
        XCTAssertEqual(retried.attemptCount, 0)
        XCTAssertFalse(retried.isFailed)
    }

    func testSendQueuesRetryableFailureAsPendingEcho() async throws {
        let accountJID = "@me:trix.selfhost.ru"
        let directoryName = "OutboxQueueTests-\(UUID().uuidString)"
        let store = Self.makeOutboxStore(directoryName: directoryName)
        defer {
            try? store.clear(accountJID: accountJID)
            try? FileManager.default.removeItem(at: trixOutboxTestRootURL(directoryName: directoryName))
        }

        let service = MockTrixService()
        await service.enqueueSendTextError(.xmppConnectionFailed)
        let viewModel = TimelineViewModel()
        viewModel.prepareForRoomSwitch(roomID: Self.dmRoomID)

        let queuedItem = await viewModel.send(
            text: "offline hello",
            roomID: Self.dmRoomID,
            session: Self.session,
            service: service,
            outboxStore: store
        )

        XCTAssertEqual(queuedItem?.deliveryState, .pending)
        XCTAssertEqual(queuedItem?.body, "offline hello")
        XCTAssertEqual(queuedItem?.isLocalEcho, true)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.items.contains(where: { $0.id == queuedItem?.id }))

        let queuedMessages = try store.load(accountJID: accountJID)
        XCTAssertEqual(queuedMessages.count, 1)
        XCTAssertEqual(queuedMessages.first?.body, "offline hello")
        XCTAssertEqual(queuedMessages.first?.roomID, Self.dmRoomID)
        XCTAssertEqual(queuedMessages.first?.attemptCount, 1)
        XCTAssertEqual(queuedMessages.first?.isFailed, false)
    }

    func testSendDoesNotQueueFatalFailures() async throws {
        let accountJID = "@me:trix.selfhost.ru"
        let directoryName = "OutboxFatalTests-\(UUID().uuidString)"
        let store = Self.makeOutboxStore(directoryName: directoryName)
        defer {
            try? store.clear(accountJID: accountJID)
            try? FileManager.default.removeItem(at: trixOutboxTestRootURL(directoryName: directoryName))
        }

        let service = MockTrixService()
        await service.enqueueSendTextError(.omemoDeviceTrustRequired)
        let viewModel = TimelineViewModel()
        viewModel.prepareForRoomSwitch(roomID: Self.dmRoomID)

        let sentItem = await viewModel.send(
            text: "needs trust",
            roomID: Self.dmRoomID,
            session: Self.session,
            service: service,
            outboxStore: store
        )

        XCTAssertNil(sentItem)
        XCTAssertEqual(
            viewModel.errorMessage,
            TrixClientError.omemoDeviceTrustRequired.trixUserFacingMessage
        )
        XCTAssertTrue(try store.load(accountJID: accountJID).isEmpty)
    }

    func testOutboxDrainFailsThenSucceedsOnRetry() async throws {
        let directoryName = "OutboxDrainTests-\(UUID().uuidString)"
        let store = Self.makeOutboxStore(directoryName: directoryName)
        let service = MockTrixService()
        let model = TrixAppModel(
            sessionStore: OutboxTestSessionStore(),
            registrationService: MockInviteRegistrationService(),
            outboxStore: store,
            trixService: service
        )
        defer {
            try? store.clear(accountJID: Self.session.userID)
            try? FileManager.default.removeItem(at: trixOutboxTestRootURL(directoryName: directoryName))
        }

        await model.installTestSession(
            Self.session,
            account: TrixAccount(
                userID: Self.session.userID,
                displayName: "Me",
                deviceID: Self.session.deviceID
            )
        )

        let queued = TrixOutboxMessage(
            id: "trix-outbox-drain",
            roomID: Self.dmRoomID,
            body: "queued while offline",
            createdAt: Date(timeIntervalSince1970: 100),
            attemptCount: 1
        )
        try store.append(queued, accountJID: Self.session.userID)

        // First drain attempt still fails with a connection error: the entry
        // must stay queued with an incremented attempt count.
        await service.enqueueSendTextError(.xmppConnectionFailed)
        let didSendWhileOffline = await model.drainOutbox()
        XCTAssertFalse(didSendWhileOffline)

        let stillQueued = try store.load(accountJID: Self.session.userID)
        XCTAssertEqual(stillQueued.map(\.id), ["trix-outbox-drain"])
        XCTAssertEqual(stillQueued.first?.attemptCount, 2)
        XCTAssertEqual(stillQueued.first?.isFailed, false)

        // Second drain succeeds: the entry is removed and the real message
        // lands in the service timeline.
        let didSendAfterReconnect = await model.drainOutbox()
        XCTAssertTrue(didSendAfterReconnect)
        XCTAssertTrue(try store.load(accountJID: Self.session.userID).isEmpty)

        let timeline = try await service.timeline(roomID: Self.dmRoomID, session: Self.session)
        XCTAssertTrue(timeline.contains(where: { $0.body == "queued while offline" && $0.deliveryState == .sent }))
    }

    func testOutboxDrainSendsRetryWithStableMessageID() async throws {
        let directoryName = "OutboxStableIDTests-\(UUID().uuidString)"
        let store = Self.makeOutboxStore(directoryName: directoryName)
        let service = MockTrixService()
        let model = TrixAppModel(
            sessionStore: OutboxTestSessionStore(),
            registrationService: MockInviteRegistrationService(),
            outboxStore: store,
            trixService: service
        )
        defer {
            try? store.clear(accountJID: Self.session.userID)
            try? FileManager.default.removeItem(at: trixOutboxTestRootURL(directoryName: directoryName))
        }

        await model.installTestSession(
            Self.session,
            account: TrixAccount(
                userID: Self.session.userID,
                displayName: "Me",
                deviceID: Self.session.deviceID
            )
        )

        let queued = TrixOutboxMessage(
            id: "trix-outbox-stable-id",
            roomID: Self.dmRoomID,
            body: "stable id message",
            createdAt: Date(timeIntervalSince1970: 100),
            attemptCount: 1
        )
        try store.append(queued, accountJID: Self.session.userID)

        // First drain fails with a connection error, the retry succeeds.
        await service.enqueueSendTextError(.xmppConnectionFailed)
        _ = await model.drainOutbox()
        _ = await model.drainOutbox()

        // The resend must carry the queued message id as the stanza id so a
        // first attempt that actually reached the server stays dedupable
        // (XEP-0359) instead of arriving as a second copy.
        let timeline = try await service.timeline(roomID: Self.dmRoomID, session: Self.session)
        let sentItem = timeline.first(where: { $0.body == "stable id message" })
        XCTAssertEqual(sentItem?.id, "trix-outbox-stable-id")
        XCTAssertEqual(sentItem?.deliveryState, .sent)
        XCTAssertTrue(try store.load(accountJID: Self.session.userID).isEmpty)
    }

    func testOutboxFileKeepsBodyEncryptedAtRest() throws {
        let accountJID = "@outbox-rest-\(UUID().uuidString):trix.selfhost.ru"
        let directoryName = "OutboxAtRestTests-\(UUID().uuidString)"
        let store = Self.makeOutboxStore(directoryName: directoryName)
        let rootURL = trixOutboxTestRootURL(directoryName: directoryName)
        defer {
            try? store.clear(accountJID: accountJID)
            try? FileManager.default.removeItem(at: rootURL)
        }

        let secretBody = "TOP-SECRET-OUTBOX-PLAINTEXT-7f3a"
        try store.append(
            TrixOutboxMessage(
                id: "trix-outbox-at-rest",
                roomID: Self.dmRoomID,
                body: secretBody,
                createdAt: Date(timeIntervalSince1970: 100),
                attemptCount: 1
            ),
            accountJID: accountJID
        )

        let storedFiles = try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(storedFiles.count, 1)

        let rawData = try Data(contentsOf: XCTUnwrap(storedFiles.first))
        XCTAssertFalse(rawData.isEmpty)
        // Neither the message body nor the room/account ids may appear in the
        // on-disk representation: only the AES-GCM envelope is stored.
        XCTAssertNil(rawData.range(of: Data(secretBody.utf8)))
        XCTAssertNil(rawData.range(of: Data(Self.dmRoomID.utf8)))
        XCTAssertNil(rawData.range(of: Data(accountJID.utf8)))

        // Sanity check: the store itself can still read the message back.
        XCTAssertEqual(try store.load(accountJID: accountJID).first?.body, secretBody)
    }

    func testOutboxDrainPreservesOrderAcrossPartialFailure() async throws {
        let directoryName = "OutboxOrderTests-\(UUID().uuidString)"
        let store = Self.makeOutboxStore(directoryName: directoryName)
        let service = MockTrixService()
        let model = TrixAppModel(
            sessionStore: OutboxTestSessionStore(),
            registrationService: MockInviteRegistrationService(),
            outboxStore: store,
            trixService: service
        )
        defer {
            try? store.clear(accountJID: Self.session.userID)
            try? FileManager.default.removeItem(at: trixOutboxTestRootURL(directoryName: directoryName))
        }

        await model.installTestSession(
            Self.session,
            account: TrixAccount(
                userID: Self.session.userID,
                displayName: "Me",
                deviceID: Self.session.deviceID
            )
        )

        let first = TrixOutboxMessage(
            id: "trix-outbox-order-first",
            roomID: Self.dmRoomID,
            body: "ordered first",
            createdAt: Date(timeIntervalSince1970: 100),
            attemptCount: 1
        )
        let second = TrixOutboxMessage(
            id: "trix-outbox-order-second",
            roomID: Self.dmRoomID,
            body: "ordered second",
            createdAt: Date(timeIntervalSince1970: 200),
            attemptCount: 1
        )
        try store.append(first, accountJID: Self.session.userID)
        try store.append(second, accountJID: Self.session.userID)

        // The first send hits a connection error: the drain must stop instead
        // of sending the newer message ahead of the stuck older one.
        await service.enqueueSendTextError(.xmppConnectionFailed)
        let didSendPartial = await model.drainOutbox()
        XCTAssertFalse(didSendPartial)

        let queuedAfterFailure = try store.load(accountJID: Self.session.userID)
        XCTAssertEqual(queuedAfterFailure.map(\.id), ["trix-outbox-order-first", "trix-outbox-order-second"])
        XCTAssertEqual(queuedAfterFailure.first?.attemptCount, 2)
        // The newer message was never attempted while the older one is stuck.
        XCTAssertEqual(queuedAfterFailure.last?.attemptCount, 1)

        // Once the connection recovers, both go out oldest-first.
        let didSendAll = await model.drainOutbox()
        XCTAssertTrue(didSendAll)
        XCTAssertTrue(try store.load(accountJID: Self.session.userID).isEmpty)

        let timeline = try await service.timeline(roomID: Self.dmRoomID, session: Self.session)
        let firstIndex = try XCTUnwrap(timeline.firstIndex(where: { $0.id == "trix-outbox-order-first" }))
        let secondIndex = try XCTUnwrap(timeline.firstIndex(where: { $0.id == "trix-outbox-order-second" }))
        XCTAssertLessThan(firstIndex, secondIndex)
    }

    func testOutboxDrainMarksMessageFailedAfterAttemptBudgetIsExhausted() async throws {
        let directoryName = "OutboxFailedTests-\(UUID().uuidString)"
        let store = Self.makeOutboxStore(directoryName: directoryName)
        let service = MockTrixService()
        let model = TrixAppModel(
            sessionStore: OutboxTestSessionStore(),
            registrationService: MockInviteRegistrationService(),
            outboxStore: store,
            trixService: service
        )
        defer {
            try? store.clear(accountJID: Self.session.userID)
            try? FileManager.default.removeItem(at: trixOutboxTestRootURL(directoryName: directoryName))
        }

        await model.installTestSession(
            Self.session,
            account: TrixAccount(
                userID: Self.session.userID,
                displayName: "Me",
                deviceID: Self.session.deviceID
            )
        )

        let queued = TrixOutboxMessage(
            id: "trix-outbox-exhausted",
            roomID: Self.dmRoomID,
            body: "exhausted message",
            createdAt: Date(timeIntervalSince1970: 100),
            attemptCount: TrixSendRetryPolicy.maxSendAttempts - 1
        )
        try store.append(queued, accountJID: Self.session.userID)

        await service.enqueueSendTextError(.xmppConnectionFailed)
        _ = await model.drainOutbox()

        let failedMessages = try store.load(accountJID: Self.session.userID)
        XCTAssertEqual(failedMessages.first?.attemptCount, TrixSendRetryPolicy.maxSendAttempts)
        XCTAssertEqual(failedMessages.first?.isFailed, true)

        // Failed entries are skipped by subsequent drains until retried.
        let didSend = await model.drainOutbox()
        XCTAssertFalse(didSend)
        XCTAssertEqual(try store.load(accountJID: Self.session.userID).first?.isFailed, true)

        // Manual retry resets the entry and drains it successfully.
        await model.retryOutboxMessage("trix-outbox-exhausted")
        XCTAssertTrue(try store.load(accountJID: Self.session.userID).isEmpty)

        let timeline = try await service.timeline(roomID: Self.dmRoomID, session: Self.session)
        XCTAssertTrue(timeline.contains(where: { $0.body == "exhausted message" }))
    }

    func testDeleteOutboxMessageRemovesQueuedEntry() async throws {
        let directoryName = "OutboxDeleteTests-\(UUID().uuidString)"
        let store = Self.makeOutboxStore(directoryName: directoryName)
        let service = MockTrixService()
        let model = TrixAppModel(
            sessionStore: OutboxTestSessionStore(),
            registrationService: MockInviteRegistrationService(),
            outboxStore: store,
            trixService: service
        )
        defer {
            try? store.clear(accountJID: Self.session.userID)
            try? FileManager.default.removeItem(at: trixOutboxTestRootURL(directoryName: directoryName))
        }

        await model.installTestSession(
            Self.session,
            account: TrixAccount(
                userID: Self.session.userID,
                displayName: "Me",
                deviceID: Self.session.deviceID
            )
        )

        let queued = TrixOutboxMessage(
            id: "trix-outbox-delete",
            roomID: Self.dmRoomID,
            body: "delete me",
            attemptCount: TrixSendRetryPolicy.maxSendAttempts,
            isFailed: true
        )
        try store.append(queued, accountJID: Self.session.userID)

        model.deleteOutboxMessage("trix-outbox-delete")

        XCTAssertTrue(try store.load(accountJID: Self.session.userID).isEmpty)
    }

    func testRetryableSendErrorClassification() {
        XCTAssertTrue(TrixSendRetryPolicy.isRetryableSendError(TrixClientError.xmppConnectionFailed))
        XCTAssertTrue(
            TrixSendRetryPolicy.isRetryableSendError(
                NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
            )
        )
        XCTAssertTrue(
            TrixSendRetryPolicy.isRetryableSendError(
                NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNRESET))
            )
        )

        XCTAssertFalse(TrixSendRetryPolicy.isRetryableSendError(TrixClientError.emptyMessage))
        XCTAssertFalse(TrixSendRetryPolicy.isRetryableSendError(TrixClientError.omemoDeviceTrustRequired))
        XCTAssertFalse(TrixSendRetryPolicy.isRetryableSendError(TrixClientError.ownDeviceTrustRequired))
        XCTAssertFalse(TrixSendRetryPolicy.isRetryableSendError(CancellationError()))
    }

    private static func makeOutboxStore(directoryName: String) -> TrixOutboxStore {
        TrixOutboxStore(
            directoryName: directoryName,
            keySource: .memory(Data(repeating: 0x3C, count: 32))
        )
    }

    private static let session = TrixSession(
        userID: "@me:trix.selfhost.ru",
        deviceID: "MOCK-OUTBOX",
        homeserverURL: URL(string: "https://trix.selfhost.ru")!,
        accessToken: "test-token",
        refreshToken: nil,
        oidcData: nil,
        sdkStoreID: "mock-outbox",
        createdAt: Date(timeIntervalSince1970: 0)
    )
}

private struct OutboxTestSessionStore: TrixSessionStore {
    func loadSession() throws -> TrixSession? {
        nil
    }

    func saveSession(_ session: TrixSession) throws {
    }

    func clearSession() throws {
    }
}

private func trixOutboxTestRootURL(directoryName: String) -> URL {
    FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    )[0]
        .appendingPathComponent("Trix", isDirectory: true)
        .appendingPathComponent(directoryName, isDirectory: true)
}
