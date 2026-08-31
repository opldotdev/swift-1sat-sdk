import BSVTransaction
import BSVWallet
import XCTest
@testable import OneSatActions

final class Bsv21RemittanceTests: XCTestCase {
    func test_ordinalDisplayNameUsesJavaScriptUTF16LimitWithoutInvalidSurrogates() {
        let fitsExactly = String(repeating: "a", count: 62) + "😀"
        XCTAssertEqual(OrdinalRemittance.displayName(fitsExactly), fitsExactly)
        XCTAssertEqual(OrdinalRemittance.displayName(fitsExactly)?.utf16.count, 64)

        let splitSurrogate = String(repeating: "a", count: 63) + "😀tail"
        let safePrefix = String(repeating: "a", count: 63)
        XCTAssertEqual(OrdinalRemittance.displayName(splitSurrogate), safePrefix)
        XCTAssertEqual(OrdinalRemittance.displayName(splitSurrogate)?.utf16.count, 63)
    }

    func test_ordinalDisplayNameReadsPartialCustomInstructionsJSON() {
        XCTAssertEqual(
            OrdinalRemittance.displayName(
                fromCustomInstructions: "{\"name\":\"Canonical Ape\"}"
            ),
            "Canonical Ape"
        )
    }

    func test_filterTags() {
        XCTAssertEqual(Bsv21Remittance.filterTags(tokenId: "abc_0"), ["bsv21:abc_0"])
        XCTAssertEqual(Bsv21Remittance.filterTags(deploy: true), ["bsv21:deploy"])
        XCTAssertEqual(
            Bsv21Remittance.filterTags(tokenId: "abc_0", deploy: true, auth: true),
            ["bsv21:abc_0", "bsv21:deploy", "bsv21:auth"]
        )
    }

    func test_customInstructionsRoundTrip() throws {
        let encoded = Bsv21Remittance.buildCustomInstructions(
            token: Bsv21Remittance.Fields(
                id: "abc_0",
                amt: "100",
                op: "transfer",
                symbol: "Demo",
                decimals: "2"
            ),
            protocolID: try OneSatConstants.p1satProtocolID,
            keyID: "k1",
            counterparty: "self"
        )
        let parsed = Bsv21Remittance.parseCustomInstructions(encoded)
        XCTAssertEqual(parsed.fields?.id, "abc_0")
        XCTAssertEqual(parsed.fields?.amt, "100")
        XCTAssertEqual(parsed.fields?.symbol, "Demo")
        XCTAssertEqual(parsed.keyID, "k1")
        XCTAssertEqual(parsed.counterparty, "self")
        let spend = try CustomInstructions.parse(encoded)
        XCTAssertEqual(spend.keyID, "k1")
        XCTAssertEqual(spend.protocolID.name, "onesat")
    }

    func test_overwriteKeepsDerivation() throws {
        let base = Bsv21Remittance.buildCustomInstructions(
            token: Bsv21Remittance.Fields(
                id: "lie_0", amt: "1", op: "transfer", symbol: "FAKE"
            ),
            protocolID: try WalletProtocolID(securityLevel: .silent, name: "p 1sat"),
            keyID: "keep-me",
            counterparty: "self"
        )
        let next = try Bsv21Remittance.overwrite(
            base, id: "real_0", amt: "500", op: "transfer", symbol: "SCAM", decimals: "10"
        )
        let parsed = Bsv21Remittance.parseCustomInstructions(next)
        XCTAssertEqual(parsed.fields?.id, "real_0")
        XCTAssertEqual(parsed.fields?.amt, "500")
        XCTAssertEqual(parsed.fields?.symbol, "SCAM")
        XCTAssertEqual(parsed.fields?.decimals, "10")
        XCTAssertEqual(parsed.keyID, "keep-me")
        XCTAssertEqual(parsed.counterparty, "self")
        let spend = try CustomInstructions.parse(next)
        XCTAssertEqual(spend.protocolID.name, "p 1sat")
    }

    func test_fieldsPreferCIOverTags() throws {
        let output = try WalletOutput(
            satoshis: 1,
            spendable: true,
            customInstructions: Bsv21Remittance.buildCustomInstructions(
                token: Bsv21Remittance.Fields(id: "fromci_0", amt: "9", symbol: "CI")
            ),
            tags: ["bsv21:fromtag_0", "amt:1", "sym:TAG"],
            outpoint: try Outpoint(ActionVectors.outpoint)
        )
        let fields = Bsv21Remittance.fields(from: output)
        XCTAssertEqual(fields.tokenId, "fromci_0")
        XCTAssertEqual(fields.amt, "9")
        XCTAssertEqual(fields.symbol, "CI")
    }

    func test_fieldsFallBackToTags() throws {
        let output = try WalletOutput(
            satoshis: 1,
            spendable: true,
            tags: ["bsv21:t_0", "amt:5", "dec:2"],
            outpoint: try Outpoint(ActionVectors.outpoint)
        )
        let fields = Bsv21Remittance.fields(from: output)
        XCTAssertEqual(fields.tokenId, "t_0")
        XCTAssertEqual(fields.amt, "5")
        XCTAssertEqual(fields.decimals, "2")
    }

    func test_deployOutpointIsTokenId() throws {
        let txid = String(repeating: "aa", count: 32)
        let output = try WalletOutput(
            satoshis: 1,
            spendable: true,
            customInstructions: Bsv21Remittance.buildCustomInstructions(
                token: Bsv21Remittance.Fields(amt: "1000000", op: "deploy+mint", symbol: "X")
            ),
            tags: ["bsv21:deploy"],
            outpoint: try Outpoint("\(txid).0")
        )
        let fields = Bsv21Remittance.fields(from: output)
        XCTAssertTrue(fields.isDeploy)
        XCTAssertEqual(fields.amt, "1000000")
        XCTAssertEqual(fields.tokenId, "\(txid)_0")
    }

    func test_authOnlyIsNotBalanceable() throws {
        let output = try WalletOutput(
            satoshis: 1,
            spendable: true,
            customInstructions: Bsv21Remittance.buildCustomInstructions(
                token: Bsv21Remittance.Fields(id: "t_0", amt: "0", op: "auth")
            ),
            tags: ["bsv21:t_0", "bsv21:auth"],
            outpoint: try Outpoint(ActionVectors.outpoint)
        )
        XCTAssertFalse(Bsv21Remittance.isBalanceable(output))
    }

    func test_ordinalRemittanceNormalizesOrigin() throws {
        let txid = String(repeating: "ab", count: 32)
        let encoded = OrdinalRemittance.buildCustomInstructions(
            protocolID: try OneSatConstants.p1satProtocolID,
            keyID: "k1",
            tags: ["origin:\(txid).0", "app:evil", "collection:\(txid)_1"],
            name: "  Hello  "
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["origin"] as? String, "\(txid)_0")
        XCTAssertEqual(object["app"] as? String, "evil")
        XCTAssertEqual(object["collection"] as? String, "\(txid)_1")
        XCTAssertEqual(object["name"] as? String, "Hello")
        XCTAssertEqual(object["keyID"] as? String, "k1")
        let spend = try CustomInstructions.parse(encoded)
        XCTAssertEqual(spend.keyID, "k1")
        XCTAssertEqual(spend.name, "Hello")
    }
}
