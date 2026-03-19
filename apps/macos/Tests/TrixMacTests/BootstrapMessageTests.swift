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
