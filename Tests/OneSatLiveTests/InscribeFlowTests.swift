import BSVKeys
import Foundation
import OneSatActions
import XCTest

/// Inscribe a ~180 KB image and a short text, with SIGMA identity signing on and off, through
/// the path the app's `InscribeService.inscribe` takes: `Inscriptions.prepare` as validation,
/// then `Inscriptions.inscribe` on a `OneSatContext` over the connected storage, with the MAP
/// entries `InscribeService.mapEntries` builds.
final class InscribeFlowTests: LiveTestCase {
    static let imageBytes = 180 * 1024

    func testInscribeImageUnsigned() async throws {
        try await inscribe(content: Self.jpegShaped(bytes: Self.imageBytes), contentType: "image/jpeg", signed: false)
    }

    func testInscribeImageSigned() async throws {
        try await inscribe(content: Self.jpegShaped(bytes: Self.imageBytes), contentType: "image/jpeg", signed: true)
    }

    func testInscribeTextUnsigned() async throws {
        try await inscribe(content: Array("1Sat live test \(UUID().uuidString)".utf8), contentType: "text/plain", signed: false)
    }

    func testInscribeTextSigned() async throws {
        try await inscribe(content: Array("1Sat live test, signed \(UUID().uuidString)".utf8), contentType: "text/plain", signed: true)
    }

    // MARK: -

    private func inscribe(content: [UInt8], contentType: String, signed: Bool) async throws {
        let a = try await fundedA()
        if signed { try await ensurePublishedIdentity(a) }
        let before = try await a.balance()

        // InscribeService.validationFailure
        _ = try Inscriptions.prepare(
            identity: a.key,
            Inscriptions.Request(content: content, contentType: contentType, signWithBAP: false),
            network: a.backend.chain.network
        )
        // InscribeService.mapEntries(type: "ord", fields: [])
        let map = [("app", "1sat-wallet"), ("type", "ord")]
        let result = await Inscriptions.inscribe(
            a.context,
            Inscriptions.Request(
                content: content,
                contentType: contentType,
                map: map,
                destination: nil,
                signWithBAP: signed
            )
        )
        XCTAssertNil(result.error, "inscribe failed: \(result.error ?? "") diagnostic: \(result.diagnostic ?? "none")")
        assertTxid(result.txid, "inscribe")
        let txid = try XCTUnwrap(result.txid)
        print("INSCRIBE \(contentType) \(content.count) bytes signed=\(signed): \(txid)")

        // Balance: one sat into the inscription plus the fee.
        let after = try await a.balance()
        let spent = before - after
        let feeCap: Int64 = content.count > 10_000 ? 60_000 : 5_000
        XCTAssertTrue((1...feeCap).contains(spent), "A's balance went \(before) -> \(after)")

        // The inscription is in the ordinals basket, one sat, carrying the content, signed or not.
        let ordinals = try await a.outputs(in: OneSatConstants.ordinalsBasket, include: .lockingScripts)
        let output = try XCTUnwrap(
            ordinals.first { $0.outpoint.transactionID.displayHex == txid },
            "no output of \(txid) in the ordinals basket"
        )
        XCTAssertEqual(output.satoshis, 1)
        let script = try XCTUnwrap(output.lockingScript)
        XCTAssertTrue(Self.contains(script, Array(content.prefix(64))), "the locking script does not carry the content")
        XCTAssertEqual(Self.contains(script, Array("SIGMA".utf8)), signed, "SIGMA marker present=\(!signed)")

        if backend.kind == .local {
            let broadcasts = try await localBroadcasts()
            XCTAssertTrue(broadcasts.contains(txid), "stub chain never saw \(txid)")
            let calls = try await localCalls(for: a.identityHex)
            printCalls(calls)
            assertCallsWithinLimits(calls)
            if content.count > 100_000 {
                // The call carrying the transaction is larger than the content and went as base64.
                let carrying = calls.filter { $0.reqBytes > content.count }
                XCTAssertFalse(carrying.isEmpty, "no storage call carried the \(content.count)-byte transaction")
                for call in carrying {
                    XCTAssertEqual(call.binaryRequestEncoding, "base64", "\(call.rpc) sent \(call.reqBytes) bytes without binary encoding")
                }
            }
        }
    }

    /// SIGMA signs with the published BAP identity; publish it once for A if it has none.
    private func ensurePublishedIdentity(_ wallet: LiveWallet) async throws {
        if try await Identity.resolveBapId(wallet.context) != nil { return }
        let published = await Identity.publish(wallet.context)
        XCTAssertNil(published.error, "publishing \(wallet.name)'s BAP identity failed: \(published.error ?? "")")
        assertTxid(published.txid, "BAP identity publication")
        print("PUBLISHED BAP identity \(published.bapId ?? "?") for \(wallet.name): \(published.txid ?? "?")")
    }

    /// A JPEG-shaped payload: SOI, APP0 marker, random filler, EOI.
    static func jpegShaped(bytes: Int) -> [UInt8] {
        var content: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0]
        content.reserveCapacity(bytes)
        var rng = SystemRandomNumberGenerator()
        while content.count < bytes - 2 { content.append(UInt8.random(in: 0...255, using: &rng)) }
        content += [0xFF, 0xD9]
        return content
    }

    static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return needle.isEmpty }
        for start in 0...(haystack.count - needle.count) where haystack[start] == needle[0] {
            if Array(haystack[start..<(start + needle.count)]) == needle { return true }
        }
        return false
    }
}
