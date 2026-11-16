import BSVCompat
import BSVCore
import BSVCrypto
import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet
import Foundation
import OneSatActions
import ToolboxActions
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

        // The inscription is in the ordinals basket, one sat, carrying the content, its type and
        // the MAP entries, signed or not.
        let output = try await a.output(of: txid, in: OneSatConstants.ordinalsBasket)
        XCTAssertEqual(output.satoshis, 1)
        let script = try Script(bytes: try XCTUnwrap(output.lockingScript), maximumByteCount: Self.maximumScriptBytes)
        let pushes = try script.operations(maximumPushDataByteCount: Self.maximumScriptBytes).map(\.pushedData)
        XCTAssertTrue(pushes.contains(content), "no push in the locking script is the full \(content.count)-byte content")
        XCTAssertTrue(pushes.contains(Array(contentType.utf8)), "no push in the locking script is the content type \(contentType)")
        for (key, value) in map {
            XCTAssertTrue(
                Self.adjacent(pushes, Array(key.utf8), Array(value.utf8)),
                "the locking script lacks the MAP pair \(key)=\(value)"
            )
        }
        let sigma = Self.sigmaFields(pushes)
        XCTAssertEqual(sigma != nil, signed, "SIGMA tape present=\(sigma != nil), signed=\(signed)")
        if signed, let sigma {
            try await assertSigma(sigma, script: script, tx: try XCTUnwrap(result.tx, "inscribe returned no transaction"), wallet: a)
        }

        if backend.kind == .local {
            let broadcasts = try await localBroadcasts()
            XCTAssertTrue(broadcasts.contains(txid), "stub chain never saw \(txid)")
            let calls = try await localCalls(for: a.identityHex)
            printCalls(calls)
            assertCallsWithinLimits(calls)
            for call in calls where call.httpMethod == "POST" && call.path == "/" {
                XCTAssertEqual(call.binaryEncodingAsked, "base64", "\(call.rpc) did not ask for binary replies")
                XCTAssertEqual(call.binaryEncodingEchoed, "base64", "\(call.rpc) reply was not binary-encoded")
            }
            if content.count > 100_000 {
                // A binary reply carries the transaction as base64. Bytes as JSON number arrays
                // (the 1.33 MB replies the toolbox fix ended) show up as an array as long as the
                // content.
                for call in calls {
                    XCTAssertLessThan(
                        call.resLongestArray, 10_000,
                        "\(call.rpc) answered an array of \(call.resLongestArray) values (\(call.resBytes) bytes)"
                    )
                }
                // The call carrying the transaction is larger than the content and went as base64.
                let carrying = calls.filter { $0.reqBytes > content.count }
                XCTAssertFalse(carrying.isEmpty, "no storage call carried the \(content.count)-byte transaction")
                for call in carrying {
                    XCTAssertEqual(call.binaryRequestEncoding, "base64", "\(call.rpc) sent \(call.reqBytes) bytes without binary encoding")
                }
            }
        }
    }

    static let maximumScriptBytes = 2_000_000

    /// The pushes after `SIGMA` (`applySigma`, `sigma.ts`): algorithm, address, signature, vin.
    struct SigmaFields {
        let algorithm: String
        let address: String
        let signature: [UInt8]
        let vin: String
    }

    static func sigmaFields(_ pushes: [[UInt8]?]) -> SigmaFields? {
        guard let at = pushes.lastIndex(of: Array("SIGMA".utf8)), pushes.count >= at + 5,
              let algorithm = pushes[at + 1], let address = pushes[at + 2],
              let signature = pushes[at + 3], let vin = pushes[at + 4]
        else { return nil }
        return SigmaFields(
            algorithm: String(decoding: algorithm, as: UTF8.self),
            address: String(decoding: address, as: UTF8.self),
            signature: signature,
            vin: String(decoding: vin, as: UTF8.self)
        )
    }

    /// The tape names A's current BAP signing address and its BSM signature verifies over
    /// `sha256(sha256(anchor txid ‖ vout LE) ‖ sha256(script before the tape))`, the message
    /// `Sigma.applyWithCreator` signs, against the input the tape names (the anchor), read from the
    /// Atomic BEEF the inscribe returned.
    private func assertSigma(_ sigma: SigmaFields, script: Script, tx: [UInt8], wallet: LiveWallet) async throws {
        XCTAssertEqual(sigma.algorithm, "BSM")
        XCTAssertEqual(sigma.vin, "0")
        XCTAssertEqual(sigma.signature.count, Sigma.compactSignatureLength)
        XCTAssertFalse(sigma.signature.allSatisfy { $0 == 0 }, "the SIGMA signature is still the zeroed placeholder")

        let keyID = try await Sigma.resolveCurrentKeyId(wallet.context)
        let signingKey = try WalletKeyDeriver(rootKey: wallet.key).derivePrivateKey(
            protocolID: try OneSatConstants.bapProtocolID,
            keyID: try WalletKeyID(keyID),
            counterparty: .self
        )
        let expected = Address(publicKey: signingKey.publicKey, network: wallet.backend.chain.network, compressed: true)
        XCTAssertEqual(sigma.address, expected.description, "SIGMA signed by \(sigma.address), A's BAP key \(keyID) is \(expected)")

        // Rebuild the tape to find where it starts, then hash what precedes it.
        var tape = try Script(bytes: [], maximumByteCount: Self.maximumScriptBytes)
        try tape.appendPushData(Array("|".utf8), maximumScriptByteCount: Self.maximumScriptBytes)
        for field in [Array("SIGMA".utf8), Array(sigma.algorithm.utf8), Array(sigma.address.utf8), sigma.signature, Array(sigma.vin.utf8)] {
            try tape.appendPushData(field, maximumScriptByteCount: Self.maximumScriptBytes)
        }
        let bytes = script.bytes
        let tapeBytes: [UInt8]
        if bytes.count >= tape.bytes.count, bytes.suffix(tape.bytes.count).elementsEqual(tape.bytes) {
            tapeBytes = tape.bytes
        } else {
            // No earlier OP_RETURN: the tape opens with OP_RETURN instead of "|".
            let separator = try Script.pushDataPrefix(forByteCount: 1).count + 1
            tapeBytes = [Opcode.return.rawValue] + Array(tape.bytes.dropFirst(separator))
            XCTAssertTrue(bytes.suffix(tapeBytes.count).elementsEqual(tapeBytes), "the SIGMA tape is not at the end of the script")
        }
        let dataHash = BSVHashing.sha256(Array(bytes.dropLast(tapeBytes.count))).bytes
        let signature = try BitcoinMessageSignature(sigma.signature)

        let atomic = try AtomicBEEF(bytes: tx, limits: WalletBEEFLimits.standard, transactionOrder: .any)
        let subject = try XCTUnwrap(
            try atomic.beef.transaction(for: atomic.subjectTransactionID, limits: WalletBEEFLimits.standard.transactionLimits),
            "the inscribe's Atomic BEEF lacks its subject transaction"
        )
        let vin = try XCTUnwrap(Int(sigma.vin), "SIGMA vin \(sigma.vin) is not a number")
        guard subject.inputs.indices.contains(vin) else {
            throw LiveSetupError("SIGMA names input \(vin); the transaction has \(subject.inputs.count)")
        }
        let anchor = subject.inputs[vin].previousOutput
        let vout = anchor.outputIndex
        let inputHash = BSVHashing.sha256(
            try Hex.decode(anchor.transactionID.displayHex, maximumDecodedByteCount: 32) + [
                UInt8(truncatingIfNeeded: vout), UInt8(truncatingIfNeeded: vout >> 8),
                UInt8(truncatingIfNeeded: vout >> 16), UInt8(truncatingIfNeeded: vout >> 24),
            ]
        ).bytes
        let message = BSVHashing.sha256(inputHash + dataHash).bytes
        XCTAssertTrue(
            try signature.verifies(message: message, address: expected),
            "the SIGMA signature does not verify against input \(vin) (\(anchor))"
        )
    }

    /// `key` then `value` as consecutive pushes.
    static func adjacent(_ pushes: [[UInt8]?], _ key: [UInt8], _ value: [UInt8]) -> Bool {
        guard pushes.count >= 2 else { return false }
        return (0..<(pushes.count - 1)).contains { pushes[$0] == key && pushes[$0 + 1] == value }
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
}
