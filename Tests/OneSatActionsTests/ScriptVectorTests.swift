import BSVKeys
import BSVScript
import OneSatTemplates
import XCTest
@testable import OneSatActions

final class ScriptVectorTests: XCTestCase {
    func test_mapSetMatchesTheTypeScriptScript() throws {
        XCTAssertEqual(
            try MapSuffix.set([("app", "1sat"), ("type", "ord")]).hex,
            ActionVectors.mapAppType
        )
        XCTAssertEqual(
            try MapSuffix.set([("name", "hello")]).hex,
            ActionVectors.mapName
        )
    }

    func test_transferLockingScriptMatchesTheTypeScriptScript() throws {
        XCTAssertEqual(
            try Ordinals.transferLockingScript(
                address: ActionVectors.templateAddress,
                map: [("app", "1sat"), ("type", "ord")]
            ).hex,
            ActionVectors.p2pkhPlusMap
        )
    }

    func test_inscribeSuffixMatchesTheTypeScriptScript() throws {
        let content = Array("Hello, BSV!".utf8)
        let recipient = try ActionScript.payToPublicKeyHash(ActionVectors.templateAddress)
        XCTAssertEqual(
            try Inscriptions.lockingScript(
                content: content,
                contentType: "text/plain",
                recipient: recipient
            ).hex,
            ActionVectors.inscribeP2PKHSuffix
        )
        XCTAssertEqual(
            try Inscriptions.lockingScript(
                content: content,
                contentType: "text/plain",
                recipient: recipient,
                map: [("name", "hello")]
            ).hex,
            ActionVectors.inscribeP2PKHMapSuffix
        )
    }

    func test_bsv21TransferMatchesTheTypeScriptScript() throws {
        let recipient = try ActionScript.payToPublicKeyHash(ActionVectors.templateAddress)
        XCTAssertEqual(
            try Tokens.transferScript(
                tokenId: ActionVectors.tokenID,
                amount: 500,
                recipient: recipient
            ).hex,
            ActionVectors.bsv21TransferP2PKH
        )
    }

    func test_timeLockMatchesTheFrozenTemplateVector() throws {
        XCTAssertEqual(
            try Locks.lockScript(address: ActionVectors.templateAddress, until: 100).hex,
            ActionVectors.lock100
        )
        XCTAssertEqual(
            try Locks.lockScript(address: ActionVectors.templateAddress, until: 100).hex,
            try TimeLock.lock(address: ActionVectors.templateAddress, until: 100).hex
        )
    }

    func test_ordLockMatchesTheFrozenTemplateVector() throws {
        XCTAssertEqual(
            try OrdLock.lock(
                cancelAddress: ActionVectors.templateAddress,
                payAddress: ActionVectors.payAddress,
                price: 50_000
            ).hex,
            ActionVectors.lock50k
        )
    }
}
