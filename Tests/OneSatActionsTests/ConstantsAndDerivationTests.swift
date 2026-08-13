import BSVCore
import BSVKeys
import BSVWallet
import XCTest
@testable import OneSatActions

final class ConstantsAndDerivationTests: XCTestCase {
    func test_constantsMatchTypesPackage() throws {
        XCTAssertEqual(OneSatConstants.ordinalsBasket, "p 1sat ordinals")
        XCTAssertEqual(OneSatConstants.bsv21Basket, "p 1sat bsv21")
        XCTAssertEqual(OneSatConstants.lockBasket, "p 1sat lock")
        XCTAssertEqual(OneSatConstants.p1satLabel, "p 1sat action")
        XCTAssertEqual(OneSatConstants.p1satProtocolName, "p 1sat")
        XCTAssertEqual(OneSatConstants.p1satProtocolSecurityLevel, 0)
        XCTAssertEqual(OneSatConstants.lockKeyID, "lock")
        XCTAssertEqual(OneSatConstants.maxInscriptionBytes, 100_000)
        XCTAssertEqual(OneSatConstants.mapPrefix, "1PuQa7K62MiKCtssSLKy1kh56WWU7MtUR5")
        XCTAssertEqual(
            OneSatConstants.inputAssetLabel(basket: "p 1sat ordinals", id: "ab_0"),
            "p 1sat input ordinals ab_0"
        )
        XCTAssertEqual(
            OneSatConstants.tokenLabel("aa_0"),
            "p 1sat bsv21 aa_0"
        )
        XCTAssertEqual(OneSatConstants.assetID(in: ["type:image/png", "id:deadbeef_1"]), "deadbeef_1")
        let protocolID = try OneSatConstants.p1satProtocolID
        XCTAssertEqual(protocolID.securityLevel, .silent)
        XCTAssertEqual(protocolID.name, "p 1sat")
    }

    func test_invoiceNumbersMatchBRC43() {
        XCTAssertEqual(P1SATKey.invoiceNumber(keyID: "lock"), "0-p 1sat-lock")
        XCTAssertEqual(
            P1SATKey.invoiceNumber(keyID: ActionVectors.outpoint),
            "0-p 1sat-\(ActionVectors.outpoint)"
        )
    }

    func test_fixedKeyDerivationMatchesTheTypeScriptPrint() throws {
        let identity = try ActionVectors.identity()
        XCTAssertEqual(
            try P1SATKey.address(
                identity: identity,
                keyID: OneSatConstants.lockKeyID,
                forSelf: true
            ).description,
            "12CeM2VABWhpmB5DA9X2FpAiBZFoQn6QLG"
        )
        XCTAssertEqual(
            try P1SATKey.address(
                identity: identity,
                keyID: ActionVectors.outpoint,
                forSelf: true
            ).description,
            "1FRgL8WGTQ7rd81M5Cj4t6d6HJPverhUVP"
        )
        let recipient = try ActionVectors.recipient()
        XCTAssertEqual(
            try P1SATKey.address(
                identity: identity,
                keyID: ActionVectors.outpoint,
                counterparty: .publicKey(recipient.publicKey),
                forSelf: false
            ).description,
            "1AEo1Xrpkkx7sB19M2igcBhgXrKH9WNEsX"
        )
        XCTAssertEqual(
            Hex.encode(identity.publicKey.compressedBytes),
            "02bd1e9f9470dad82f75c4ffd03ffe9a5ddc2c5a718084727c027b17e9b7cfd8a5"
        )
    }

    func test_customInstructionsRoundTrip() throws {
        let encoded = try CustomInstructions(
            keyID: "lock"
        ).encoded()
        XCTAssertEqual(encoded, "{\"protocolID\":[0,\"p 1sat\"],\"keyID\":\"lock\"}")
        let parsed = try CustomInstructions.parse(encoded)
        XCTAssertEqual(parsed.keyID, "lock")
        XCTAssertEqual(parsed.protocolID.name, "p 1sat")
        XCTAssertEqual(parsed.counterparty, .self)
    }
}
