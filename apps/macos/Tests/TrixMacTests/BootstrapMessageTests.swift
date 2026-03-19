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
