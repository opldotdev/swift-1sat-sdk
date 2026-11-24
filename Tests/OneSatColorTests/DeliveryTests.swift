import XCTest
import BSVCore
import BSVKeys
import OneSatCBOR
import OneSatMetanet
@testable import OneSatColor

/// `Delivery.sendEnvelope` as a caller outside the module uses it: with the envelope's `payment`
/// given and a hook that runs right before the post.
final class DeliveryTests: XCTestCase {
    private struct Stop: Error {}

    private func bobResolution(_ world: ColorWorld) -> HandleResolver.Resolution {
        HandleResolver.Resolution(
            metanetHandles: "1.0", handle: "bob", domain: "example.com", identityKey: world.bob.key,
            messagebox: "https://mb.example.com", ttl: 60, revoked: false
        )
    }

    func test_theEnvelopeCarriesThePaymentAndIsPostedAfterTheHook() async throws {
        let world = try ColorWorld()
        let payment = DagCborValue.map(try DagCborMap([
            ("protocol", .text("3241645161d8")),
            ("satoshis", .unsigned(1_000)),
        ]))
        let plaintext = Array("hello bob".utf8)
        var hookRuns = 0
        let sent = try await Delivery.sendEnvelope(
            identity: world.alice.identity, resolution: bobResolution(world),
            recipientKey: world.bob.identity.publicKey, plaintext: plaintext, payment: payment,
            messageBox: "payment_inbox", relay: world.alice.ctx.relay,
            beforePost: { hookRuns += 1 }
        )

        XCTAssertEqual(hookRuns, 1)
        let stored = await world.server.messages
        XCTAssertEqual(stored.count, 1)
        let message = try XCTUnwrap(stored.first)
        XCTAssertEqual(sent.messageID, message.id)
        XCTAssertEqual(message.box, "payment_inbox")
        XCTAssertEqual(message.recipient, world.bob.key)

        let envelope = try MetanetEnvelope.decode(message.body)
        XCTAssertEqual(try DagCbor.encode(envelope.payment), try DagCbor.encode(payment))
        XCTAssertEqual(envelope.senderIdentityKey, world.alice.identity.publicKey.compressedBytes)
        XCTAssertEqual(envelope.contentHash?.count, 32)
        let valid = await MetanetEnvelope.verify(envelope)
        XCTAssertTrue(valid)
    }

    func test_withoutAPaymentTheEnvelopeSaysNull() async throws {
        let world = try ColorWorld()
        _ = try await Delivery.sendEnvelope(
            identity: world.alice.identity, resolution: bobResolution(world),
            recipientKey: world.bob.identity.publicKey, plaintext: [1, 2, 3],
            messageBox: OneColorConstants.transactionDeliveryBox, relay: world.alice.ctx.relay
        )
        let stored = await world.server.messages
        let envelope = try MetanetEnvelope.decode(try XCTUnwrap(stored.first).body)
        XCTAssertEqual(envelope.payment, .null)
    }

    func test_aHookThatThrowsStopsThePost() async throws {
        let world = try ColorWorld()
        do {
            _ = try await Delivery.sendEnvelope(
                identity: world.alice.identity, resolution: bobResolution(world),
                recipientKey: world.bob.identity.publicKey, plaintext: [1],
                messageBox: "payment_inbox", relay: world.alice.ctx.relay,
                beforePost: { throw Stop() }
            )
            XCTFail("the post went ahead")
        } catch is Stop {}
        let stored = await world.server.messages
        XCTAssertTrue(stored.isEmpty)
    }
}
