import Foundation
import XCTest
import BSVCore
import BSVTransaction
import OneSatTemplates
@testable import OneSatColor

/// Each message equals its TS literal: `@bsv/color-permission-module` (ColorPlan.ts,
/// strictJson.ts, identifiers.ts, tokenOutputs.ts, ColorPermissionModule.ts `parseCustody`) and
/// `@1sat/actions` 1color/receipt.ts.
final class ColorErrorTextTests: XCTestCase {
    private let asset = String(repeating: "ab", count: 32) + "_0"
    private let otherAsset = String(repeating: "cd", count: 32) + "_1"
    private let txid = String(repeating: "ab", count: 32)
    private let key = "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
    /// Well formed, but x = 5 is on no point of secp256k1.
    private let offCurveKey = "02" + String(repeating: "00", count: 31) + "05"
    /// 66 bytes: `1` and a combining mark is one character, which sorts between "0" and "9".
    private let markedKey = "02" + "1\u{301}" + String(repeating: "a", count: 61)

    private func assertMessage(
        _ expression: @autoclosure () throws -> Any?, _ message: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) {
            XCTAssertEqual(($0 as? ColorError)?.errorDescription, message, file: file, line: line)
        }
    }

    /// `p color plan` labels carrying `text` as given, 100 bytes to a label.
    private func planLabels(_ text: String) -> [String] {
        planLabels(bytes: Array(text.utf8))
    }

    private func planLabels(bytes: [UInt8]) -> [String] {
        let hex = Array(Hex.encode(bytes))
        let count = (hex.count + 199) / 200
        return (0..<count).map { i in
            "p color plan \(i) \(count) \(String(hex[(i * 200)..<min(hex.count, (i + 1) * 200)]))"
        }
    }

    private func plan(
        assets: String = "[]", owned: String = "[]", operations: String = "[]", inputs: String = "[]",
        changes: String = "[]", sighashes: String = "[]", extra: String = ""
    ) -> [String] {
        planLabels(#"{"version":1,"assets":\#(assets),"ownedOutputs":\#(owned),"operations":\#(operations),"inputPositions":\#(inputs),"changePositions":\#(changes),"sighashTypes":\#(sighashes)\#(extra)}"#)
    }

    private func remittance(prefix: String = #""cA==""#, sender: String? = nil) -> String {
        #"[{"outputIndex":0,"assetId":"\#(asset)","derivationPrefix":\#(prefix),"derivationSuffix":"cw==","senderIdentityKey":"\#(sender ?? key)"}]"#
    }

    private func receiptJSON(asset: String? = nil, prefix: String = "cA==", sender: String? = nil, version: Int = 1) -> String {
        #"{"version":\#(version),"assetId":"\#(asset ?? self.asset)","derivationPrefix":"\#(prefix)","derivationSuffix":"cw==","senderIdentityKey":"\#(sender ?? key)"}"#
    }

    // MARK: - ColorPlan.ts `fromLabels`

    func test_planLabelMessagesMatchTS() {
        let full = String(repeating: "20", count: 100)
        assertMessage(try ColorPlan.fromLabels(["p color plan 0 2 \(full)", "p color plan 1 3 7d"]), "BRC-207: inconsistent plan part counts")
        assertMessage(try ColorPlan.fromLabels(["p color plan 1 1 7b7d"]), "BRC-207: plan part index out of range")
        assertMessage(try ColorPlan.fromLabels(["p color plan 0 1 7b7d", "p color plan 0 1 7b7d"]), "BRC-207: duplicate plan part")
        assertMessage(try ColorPlan.fromLabels(["p color plan 0 2 7b7d"]), "BRC-207: short nonfinal plan chunk")
        assertMessage(try ColorPlan.fromLabels(["p color plan 1 2 7b7d"]), "BRC-207: missing plan part")
        assertMessage(try ColorPlan.fromLabels(["p color plan 0 1 7b7"]), "BRC-207: invalid plan chunk")
    }

    // MARK: - ColorPlan.ts `parsePlan`, strictJson.ts

    func test_planMessagesMatchTS() {
        let outpoint = "\"\(txid).0\""
        assertMessage(try ColorPlan.fromLabels(planLabels(bytes: [0xff])), "BRC-207: plan is not strict UTF-8")
        assertMessage(try ColorPlan.fromLabels(planLabels(#"{"a":1,"a":2}"#)), "BRC-207: plan is not strict JSON (duplicate member a)")
        assertMessage(try ColorPlan.fromLabels(planLabels("[]")), "BRC-207: plan must be a JSON object")
        assertMessage(try ColorPlan.fromLabels(planLabels(#"{"version":1}"#)), "BRC-207: plan is missing assets")
        assertMessage(try ColorPlan.fromLabels(plan(extra: #","x":1"#)), "BRC-207: plan has unknown member x")
        assertMessage(
            try ColorPlan.fromLabels(planLabels(#"{"version":2,"assets":[],"ownedOutputs":[],"operations":[],"inputPositions":[],"changePositions":[],"sighashTypes":[]}"#)),
            "BRC-207: plan version must be 1"
        )
        assertMessage(try ColorPlan.fromLabels(plan(assets: "{}")), "BRC-207: plan.assets must be an array")
        assertMessage(try ColorPlan.fromLabels(plan(assets: "[1]")), "BRC-207: invalid asset ID")
        assertMessage(try ColorPlan.fromLabels(plan(assets: #"["\#(asset)","\#(asset)"]"#)), "BRC-207: duplicate plan asset")
        assertMessage(
            try ColorPlan.fromLabels(plan(assets: #"["\#(asset)"]"#, operations: #"[{"assetId":"\#(asset)","operation":"x"}]"#)),
            "BRC-207: plan.operations[0] has an unknown operation"
        )
        assertMessage(try ColorPlan.fromLabels(plan(operations: "[1]")), "BRC-207: plan.operations[0] must be a JSON object")
        assertMessage(try ColorPlan.fromLabels(plan(inputs: #"[{"outpoint":1,"index":0}]"#)), "BRC-207: invalid outpoint")
        assertMessage(
            try ColorPlan.fromLabels(plan(inputs: #"[{"outpoint":\#(outpoint),"index":-1}]"#)),
            "BRC-207: plan.inputPositions[0].index must be an integer in 0..2^32-1"
        )
        assertMessage(
            try ColorPlan.fromLabels(plan(changes: #"[{"assetId":1,"index":0}]"#)), "BRC-207: invalid asset ID"
        )
        assertMessage(
            try ColorPlan.fromLabels(plan(sighashes: #"[{"outpoint":\#(outpoint),"sighashType":256}]"#)),
            "BRC-207: plan.sighashTypes[0].sighashType must be in 0..255"
        )
        assertMessage(
            try ColorPlan.fromLabels(plan(operations: #"[{"assetId":"\#(asset)","operation":"transfer"}]"#)),
            "BRC-207: plan references \(asset) outside plan.assets"
        )
        assertMessage(try ColorPlan.fromLabels(plan(assets: #"["ISSUE"]"#)), "BRC-207: a deploy plan has exactly one deploy operation")
    }

    func test_planRemittanceMessagesMatchTS() {
        let assets = #"["\#(asset)"]"#
        assertMessage(
            try ColorPlan.fromLabels(plan(assets: assets, owned: remittance(prefix: #""""#))),
            "BRC-207: plan.ownedOutputs[0].derivationPrefix must be a nonempty string without whitespace"
        )
        assertMessage(
            try ColorPlan.fromLabels(plan(assets: assets, owned: remittance(prefix: "5"))),
            "BRC-207: plan.ownedOutputs[0].derivationPrefix must be a nonempty string without whitespace"
        )
        assertMessage(
            try ColorPlan.fromLabels(plan(assets: assets, owned: remittance(sender: markedKey))),
            "BRC-207: plan.ownedOutputs[0].senderIdentityKey must be a compressed public key in lowercase hex"
        )
        assertMessage(
            try ColorPlan.fromLabels(plan(assets: assets, owned: remittance(sender: offCurveKey))),
            "BRC-207: plan.ownedOutputs[0].senderIdentityKey is not a valid public key (Invalid point)"
        )
    }

    // MARK: - identifiers.ts

    func test_identifierMessagesMatchTS() {
        assertMessage(try ColorIdentifiers.parseBasket("p color issue"), "BRC-207: issue is not a stored basket")
        assertMessage(
            try ColorIdentifiers.protocolName(.issue, derivationPrefix: "a b", derivationSuffix: "c"),
            "BRC-207: derivationPrefix must be a nonempty string without whitespace"
        )
        assertMessage(
            try ColorIdentifiers.parseProtocolName("p color issue 61 20"),
            "BRC-207: derivationSuffix must be a nonempty string without whitespace"
        )
        assertMessage(
            try ColorIdentifiers.validateIdentityKey(markedKey, name: "senderIdentityKey"),
            "BRC-207: senderIdentityKey must be a compressed public key in lowercase hex"
        )
        assertMessage(
            try ColorIdentifiers.validateIdentityKey(offCurveKey, name: "senderIdentityKey"),
            "BRC-207: senderIdentityKey is not a valid public key (Invalid point)"
        )
        XCTAssertNoThrow(try ColorIdentifiers.validateIdentityKey(key, name: "senderIdentityKey"))
    }

    // MARK: - tokenOutputs.ts

    func test_tokenOutputMessagesMatchTS() throws {
        let lock = OneColorLock.publicKeyHash([UInt8](repeating: 1, count: 20))
        let deploy = try OneColor.deployValue(amount: 1, lock: lock).lock()
        assertMessage(try ColorTokenOutput.read(deploy, txid: txid, vout: 1), "BRC-207: a BRC-162 deploy must be output 0")
        // DAG-CBOR {"req": 1} and {"ext": 1}.
        let req = try OneColor.deployValue(amount: 1, lock: lock, payload: .bytes([0xa1, 0x63, 0x72, 0x65, 0x71, 0x01])).lock()
        assertMessage(try ColorTokenOutput.read(req, txid: txid, vout: 0), "BRC-207: malformed req in a BRC-162 payload")
        let ext = try OneColor.deployValue(amount: 1, lock: lock, payload: .bytes([0xa1, 0x63, 0x65, 0x78, 0x74, 0x01])).lock()
        assertMessage(try ColorTokenOutput.read(ext, txid: txid, vout: 0), "BRC-207: malformed ext in a BRC-162 payload")
    }

    // MARK: - receipt.ts `parseColorReceipt`, `checkColorReceipt`

    func test_receiptMessagesMatchTS() throws {
        assertMessage(try ColorReceipt(customInstructions: "{"), "BRC-207: receipt customInstructions are not JSON")
        assertMessage(try ColorReceipt(customInstructions: receiptJSON(version: 2)), "BRC-207: malformed receipt customInstructions")
        assertMessage(try ColorReceipt(customInstructions: receiptJSON(asset: "ISSUE")), "BRC-207: malformed receipt customInstructions")
        // `IDENTITY_KEY` fails on the mark, as TS fails it.
        assertMessage(try ColorReceipt(customInstructions: receiptJSON(sender: markedKey)), "BRC-207: malformed receipt customInstructions")
        // `colorProtocolID` reads the remittance strings before the asset ID.
        assertMessage(
            try ColorReceipt(customInstructions: receiptJSON(asset: "x", prefix: "")),
            "BRC-207: derivationPrefix must be a nonempty string without whitespace"
        )
        assertMessage(try ColorReceipt(customInstructions: receiptJSON(asset: "x")), "BRC-207: invalid asset ID")
        assertMessage(
            try ColorReceipt(customInstructions: receiptJSON().replacingOccurrences(of: #","assetId""#, with: #", "assetId""#)),
            "BRC-207: receipt customInstructions must be exactly {version, assetId, derivationPrefix, derivationSuffix, senderIdentityKey}"
        )
        // TS checks the key's form only; the module's custody parse refuses it off the curve.
        let offCurve = receiptJSON(sender: offCurveKey)
        XCTAssertEqual(try ColorReceipt(customInstructions: offCurve).senderIdentityKey, offCurveKey)
        assertMessage(
            try ColorCustody.parse(offCurve, maxBytes: ColorCustody.maximumReceiptBytes, label: "receipt customInstructions"),
            "BRC-207: receipt customInstructions.senderIdentityKey is not a valid public key (Invalid point)"
        )
    }

    func test_receiptCheckMessagesMatchTS() throws {
        let assetID = try ColorAssetID(asset)
        let other = try ColorAssetID(otherAsset)
        let script = try OneColor.value(tokenID: asset, amount: 5, lock: .publicKeyHash([UInt8](repeating: 1, count: 20))).lock()
        let subject = Transaction(version: 1, inputs: [], outputs: [TransactionOutput(satoshis: 1, lockingScript: script)], lockTime: 0)
        let instructions = receiptJSON()
        assertMessage(
            try ColorReceipt.check(subject: subject, outputIndex: 0, basket: "p color assets", customInstructions: instructions),
            "BRC-207: p color assets is not a per-asset p color basket"
        )
        assertMessage(
            try ColorReceipt.check(
                subject: subject, outputIndex: 0, basket: ColorIdentifiers.basket(other, role: .value), customInstructions: instructions
            ),
            "BRC-207: the receipt names \(asset), the basket \(otherAsset)"
        )
        // TS throws this one without the `BRC-207: ` prefix.
        assertMessage(
            try ColorReceipt.check(
                subject: subject, outputIndex: 0, basket: ColorIdentifiers.basket(assetID, role: .authority), customInstructions: instructions
            ),
            "output 0: not a 1Color authority output of \(asset)"
        )
        XCTAssertEqual(
            try ColorReceipt.check(subject: subject, outputIndex: 0, basket: ColorIdentifiers.basket(assetID, role: .value), customInstructions: instructions).role,
            .value
        )
    }

    // MARK: - ColorPermissionModule.ts `parseCustody`

    func test_custodyMessagesMatchTS() {
        let label = "receipt customInstructions"
        func parse(_ text: String) throws -> ColorCustody {
            try ColorCustody.parse(text, maxBytes: ColorCustody.maximumReceiptBytes, label: label)
        }
        func custody(asset: String? = nil, prefix: String? = nil, profileData: String? = nil, version: Int = 1) -> String {
            let profile = profileData.map { #","profileData":\#($0)"# } ?? ""
            return #"{"version":\#(version),"assetId":\#(asset ?? "\"\(self.asset)\""),"derivationPrefix":\#(prefix ?? #""cA==""#),"derivationSuffix":"cw==","senderIdentityKey":"\#(key)"\#(profile)}"#
        }
        XCTAssertNoThrow(try parse(custody()))
        assertMessage(try parse("[]"), "BRC-207: receipt customInstructions must be a JSON object")
        assertMessage(try parse(custody(version: 2)), "BRC-207: receipt customInstructions version must be 1")
        assertMessage(try parse(custody(profileData: "[]")), "BRC-207: receipt customInstructions.profileData must be a JSON object")
        assertMessage(try parse(custody(profileData: #"{"p":1}"#)), "BRC-207: receipt customInstructions.profileData.p must be a JSON object")
        assertMessage(try parse(custody(profileData: #"{"p":{"x":1}}"#)), "BRC-207: invalid asset ID")
        assertMessage(
            try parse(custody(profileData: #"{"p":{}}"#)),
            "BRC-207: receipt customInstructions.profileData names a profile the asset does not require"
        )
        assertMessage(try parse(custody(asset: "1")), "BRC-207: invalid asset ID")
        assertMessage(
            try parse(custody(prefix: "1")),
            "BRC-207: receipt customInstructions.derivationPrefix must be a nonempty string without whitespace"
        )
    }
}
