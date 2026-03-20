import Foundation
import Testing
@testable import TrixMac

@Test
func bootstrapMessageMatchesServerLayout() {
    let transport = Data([0xAA, 0xBB, 0xCC])
    let credentialIdentity = Data([0x01, 0x02])

    let message = DeviceIdentityMaterial.bootstrapMessage(
        transportPublicKey: transport,
        credentialIdentity: credentialIdentity
    )

    #expect(
        message
            == Data("trix-account-bootstrap:v1".utf8)
            + Data([0x00, 0x00, 0x00, 0x03])
            + transport
            + Data([0x00, 0x00, 0x00, 0x02])
            + credentialIdentity
    )
}

@Test
func ffiBootstrapPayloadMatchesServerLayout() {
    let transport = Data([0xAA, 0xBB, 0xCC])
    let credentialIdentity = Data([0x01, 0x02])
    let accountRoot = FfiAccountRootMaterial.generate()

    let payload = accountRoot.accountBootstrapPayload(
        transportPubkey: transport,
        credentialIdentity: credentialIdentity
    )

    #expect(
        payload
            == DeviceIdentityMaterial.bootstrapMessage(
                transportPublicKey: transport,
                credentialIdentity: credentialIdentity
            )
    )
}

@Test
func normalizedURLAddsDefaultScheme() {
    let url = ServerEndpoint.normalizedURL(from: "127.0.0.1:8080")

    #expect(url?.absoluteString == "http://127.0.0.1:8080/")
}

@Test
func revokeMessageMatchesServerLayout() {
    let deviceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let reason = "device revoked"

    let message = DeviceIdentityMaterial.revokeMessage(deviceID: deviceID, reason: reason)
    let deviceIDBytes = Data(deviceID.uuidString.utf8)
    let reasonBytes = Data(reason.utf8)

    #expect(
        message
            == Data("trix-device-revoke:v1".utf8)
            + Data([0x00, 0x00, 0x00, UInt8(deviceIDBytes.count)])
            + deviceIDBytes
            + Data([0x00, 0x00, 0x00, UInt8(reasonBytes.count)])
            + reasonBytes
    )
}

@Test
func ffiDeviceRevokePayloadMatchesServerLayout() throws {
    let deviceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let reason = "device revoked"
    let accountRoot = FfiAccountRootMaterial.generate()

    let payload = try accountRoot.deviceRevokePayload(
        deviceId: deviceID.uuidString,
        reason: reason
    )

    #expect(payload == DeviceIdentityMaterial.revokeMessage(deviceID: deviceID, reason: reason))
}

@Test
func persistedSessionDecodesLegacyPayloadWithoutDeviceStatus() throws {
    let json = """
    {
      "baseURLString": "http://127.0.0.1:8080",
      "accountId": "11111111-1111-1111-1111-111111111111",
      "deviceId": "22222222-2222-2222-2222-222222222222",
      "accountSyncChatId": "33333333-3333-3333-3333-333333333333",
      "profileName": "Legacy",
      "handle": "legacy",
      "deviceDisplayName": "This Mac"
    }
    """.data(using: .utf8)!

    let decoded = try JSONDecoder().decode(PersistedSession.self, from: json)

    #expect(decoded.deviceStatus == .active)
    #expect(decoded.accountSyncChatId == UUID(uuidString: "33333333-3333-3333-3333-333333333333"))
}

@Test
func ffiKeyMaterialSignsAndVerifies() throws {
    let payload = Data("ffi-roundtrip".utf8)
    let keyMaterial = FfiAccountRootMaterial.generate()
    let signature = keyMaterial.sign(payload: payload)

    try keyMaterial.verify(payload: payload, signature: signature)

    #expect(!signature.isEmpty)
    #expect(!keyMaterial.publicKeyBytes().isEmpty)
}

@Test
func ffiParsesPlaintextTextBody() throws {
    let body = try TypedMessageBody(
        ffiValue: ffiParseMessageBody(
            contentType: .text,
            payload: Data("hello from ffi".utf8)
        )
    )

    #expect(body.kind == .text)
    #expect(body.text == "hello from ffi")
}

@Test
func ffiSerializesAndParsesReactionBodyRoundTrip() throws {
    let targetMessageId = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    let original = TypedMessageBody(
        kind: .reaction,
        text: nil,
        targetMessageId: targetMessageId,
        emoji: "🔥",
        reactionAction: .add,
        receiptType: nil,
        receiptAtUnix: nil,
        blobId: nil,
        mimeType: nil,
        sizeBytes: nil,
        sha256: nil,
        fileName: nil,
        widthPx: nil,
        heightPx: nil,
        fileKey: nil,
        nonce: nil,
        eventType: nil,
        eventJson: nil
    )

    let encoded = try ffiSerializeMessageBody(body: original.ffiValue())
    let decoded = try TypedMessageBody(
        ffiValue: ffiParseMessageBody(contentType: .reaction, payload: encoded)
    )

    #expect(decoded.kind == .reaction)
    #expect(decoded.targetMessageId == targetMessageId)
    #expect(decoded.emoji == "🔥")
    #expect(decoded.reactionAction == .add)
}

@Test
func messageEnvelopeAcceptsNullAadJson() throws {
    let envelope = try MessageEnvelope(
        ffiValue: FfiMessageEnvelope(
            messageId: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            chatId: "11111111-2222-3333-4444-555555555555",
            serverSeq: 1,
            senderAccountId: "99999999-8888-7777-6666-555555555555",
            senderDeviceId: "12345678-1234-1234-1234-1234567890ab",
            epoch: 0,
            messageKind: .commit,
            contentType: .chatEvent,
            ciphertext: Data([0x01, 0x02, 0x03]),
            aadJson: "null",
            createdAtUnix: 1
        )
    )

    #expect(envelope.aadJson.isEmpty)
}
