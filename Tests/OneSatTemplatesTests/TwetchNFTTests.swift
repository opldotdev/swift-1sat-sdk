import Foundation
import XCTest
@testable import OneSatTemplates

/// Mirrors `@1sat/wallet` `TwetchIndexer.test.ts`.
final class TwetchNFTTests: XCTestCase {
    /// Muties #15: output 14 of a7595e9f7400390d34f193a4011212ddebc7c2065716db525c399bb91856665b.
    private func muties() throws -> [UInt8] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "Fixtures/twetch_muties_15", withExtension: "hex")
                ?? Bundle.module.url(forResource: "twetch_muties_15", withExtension: "hex", subdirectory: "Fixtures")
        )
        let hex = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return Array(hex: hex)
    }

    /// The Muties prefix (hash lock, P2PKH, OP_RETURN) with other JSON pushed after it.
    private func withJSON(_ json: String) throws -> [UInt8] {
        let data = Array(json.utf8)
        precondition(data.count <= 0x4b)
        return Array(try muties()[0..<49]) + [UInt8(data.count)] + data
    }

    func test_readsTheOwnerAndMetadataOfAMutiesOutput() throws {
        let nft = try XCTUnwrap(TwetchNFT.decode(bytes: try muties()))
        // 1J82Vbt4Uz8kKr2Xb3Kro9WtCh6udoctCJ
        XCTAssertEqual(nft.ownerHash, Array(hex: "bbce4be495a38f3513891a3f27f90170f7ad5c41"))
        XCTAssertEqual(nft.hashLock, Array(hex: "414cc1fb9b5114dec30ced7446d88574d959f131"))
        XCTAssertEqual(nft.tags, ["twetch", "name:Muties #15"])
        XCTAssertEqual(nft.image, "b://55068f35629f5fa80866882efba1cf86782e86130e2a35091965e4e577f7abcf")
        XCTAssertEqual(nft.number, 15)
        XCTAssertEqual(nft.series, 456)
        XCTAssertEqual(nft.rarity, "Rare")
        XCTAssertEqual(nft.rank, 78)
        XCTAssertEqual(nft.attributes.count, 4)
        XCTAssertEqual(nft.attributes.first, .init(traitType: "Background", value: "Love Roses", rarity: "Common"))
    }

    func test_readsNumbersGivenAsStrings() throws {
        let nft = try XCTUnwrap(TwetchNFT.decode(bytes: try withJSON(#"{"title":"X","number":"7"}"#)))
        XCTAssertEqual(nft.number, 7)
        XCTAssertEqual(nft.tags, ["twetch", "name:X"])
    }

    func test_ignoresOtherScripts() throws {
        let p2pkh = Array(hex: "76a914bbce4be495a38f3513891a3f27f90170f7ad5c4188ac")
        XCTAssertNil(TwetchNFT.decode(bytes: p2pkh))
        XCTAssertNil(TwetchNFT.decode(bytes: try withJSON("hello")))
        XCTAssertNil(TwetchNFT.decode(bytes: try withJSON(#"{"foo":1}"#)))
        XCTAssertNil(TwetchNFT.decode(bytes: Array(try muties()[0..<48])))
        XCTAssertNil(TwetchNFT.decode(bytes: Array(try muties()[0..<60])))
    }

    func test_capsALongTitleInItsNameTag() {
        let title = String(repeating: "x", count: 63) + "\u{1F600}" + String(repeating: "y", count: 10)
        XCTAssertEqual(TwetchNFT.capName(title), String(repeating: "x", count: 63))
        XCTAssertEqual(TwetchNFT.capName("Muties #15"), "Muties #15")
    }
}
