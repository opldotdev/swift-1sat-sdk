import BSVCore
import BSVKeys
import BSVWallet
import XCTest
@testable import OneSatActions

final class ConstantsAndDerivationTests: XCTestCase {
    func test_constantsMatchTypesPackage() throws {
        XCTAssertEqual(OneSatConstants.ordinalsBasket, "1sat")
        XCTAssertEqual(OneSatConstants.onesatBasket, "1sat")
        XCTAssertEqual(OneSatConstants.bsv21Basket, "bsv21")
        XCTAssertEqual(OneSatConstants.lockBasket, "lock")
        XCTAssertEqual(OneSatConstants.opnsBasket, "opns")
        XCTAssertEqual(OneSatConstants.sigmaBasket, "sigma")
        XCTAssertEqual(OneSatConstants.p1satLabel, "p 1sat action")
        XCTAssertEqual(OneSatConstants.p1satProtocolName, "onesat")
        XCTAssertEqual(OneSatConstants.legacyP1SatProtocolName, "p 1sat")
        XCTAssertEqual(OneSatConstants.p1satProtocolSecurityLevel, 0)
        XCTAssertEqual(OneSatConstants.lockKeyID, "lock")
        XCTAssertEqual(OneSatConstants.maxInscriptionBytes, 900_000)
        XCTAssertEqual(OneSatConstants.mapPrefix, "1PuQa7K62MiKCtssSLKy1kh56WWU7MtUR5")
        XCTAssertEqual(
            OneSatConstants.inputAssetLabel(basket: "1sat", id: "ab_0"),
            "p 1sat input id ab_0"
        )
        XCTAssertEqual(
            OneSatConstants.inputAssetLabel(basket: "bsv21", id: "tok"),
            "p bsv21 input id tok"
        )
        XCTAssertEqual(
            OneSatConstants.tokenLabel("aa_0"),
            "p bsv21 token aa_0"
        )
        XCTAssertEqual(OneSatConstants.assetID(in: ["type:image/png", "id:deadbeef_1"]), "deadbeef_1")
        let protocolID = try OneSatConstants.p1satProtocolID
        XCTAssertEqual(protocolID.securityLevel, .silent)
        XCTAssertEqual(protocolID.name, "onesat")
    }

    func test_bsv20BasketIsPlain() {
        XCTAssertEqual(OneSatConstants.bsv20Basket, "bsv20")
    }

    func test_legacyBasketMigrationsMatchTypesPackage() {
        XCTAssertEqual(OneSatConstants.legacyP1SatBasketMigrations.map(\.from), [
            "p 1sat ordinals",
            "ordinals",
            "p 1sat bsv21",
            "p 1sat opns",
            "p 1sat hosting",
            "p 1sat lock",
            "p 1sat sigma",
            "p 1sat bsocial",
            "p 1sat bsv20",
        ])
        XCTAssertEqual(OneSatConstants.legacyP1SatBasketMigrations.map(\.to), [
            "1sat",
            "1sat",
            "bsv21",
            "opns",
            "hosting",
            "lock",
            "sigma",
            "bsocial",
            "bsv20",
        ])
    }

    func test_invoiceNumbersMatchBRC43() {
        XCTAssertEqual(P1SATKey.invoiceNumber(keyID: "lock"), "0-onesat-lock")
        XCTAssertEqual(
            P1SATKey.invoiceNumber(keyID: ActionVectors.outpoint),
            "0-onesat-\(ActionVectors.outpoint)"
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
            "1Q8e214jnxPd7gqoKJwWuAn436hPTVFM2V"
        )
        XCTAssertEqual(
            try P1SATKey.address(
                identity: identity,
                keyID: ActionVectors.outpoint,
                forSelf: true
            ).description,
            "1F5UNyuueGgsrGjevcLuicSwtQv8oXxMeS"
        )
        let recipient = try ActionVectors.recipient()
        XCTAssertEqual(
            try P1SATKey.address(
                identity: identity,
                keyID: ActionVectors.outpoint,
                counterparty: .publicKey(recipient.publicKey),
                forSelf: false
            ).description,
            "1y3Eyqwy4KqDUELEw58CsuL36QL6mFw35"
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
        XCTAssertEqual(encoded, "{\"protocolID\":[0,\"onesat\"],\"keyID\":\"lock\"}")
        let parsed = try CustomInstructions.parse(encoded)
        XCTAssertEqual(parsed.keyID, "lock")
        XCTAssertEqual(parsed.protocolID.name, "onesat")
        XCTAssertEqual(parsed.counterparty, .self)
    }

    func test_customInstructionsParseHonorsLegacyProtocolName() throws {
        let parsed = try CustomInstructions.parse(
            "{\"protocolID\":[0,\"p 1sat\"],\"keyID\":\"lock\"}"
        )
        XCTAssertEqual(parsed.protocolID.name, "p 1sat")
        XCTAssertEqual(parsed.keyID, "lock")
    }
}
