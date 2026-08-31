import BSVCore
import BSVTransaction
import BSVWallet
import XCTest
@testable import OneSatActions

final class CollectionParseTests: XCTestCase {
    private let parentVectorId =
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef_1"
    private let goTxid = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    private let absID = "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899_0"
    private let itemCollectionId = String(repeating: "b", count: 64) + "_1"
    private let originTxid = String(repeating: "a", count: 64)

    func test_parentBytesMatchesReversedTxidAndLittleEndianVout() throws {
        let bytes = try CollectionParse.parentBytes(collectionId: parentVectorId)
        XCTAssertEqual(bytes.count, 36)
        XCTAssertEqual(
            Hex.encode(bytes),
            String(repeating: "efcdab8967452301", count: 4) + "01000000"
        )
    }

    func test_parentBytesRejectsPeriodAndRelativeForms() {
        let period = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef.0"
        XCTAssertThrowsError(try CollectionParse.parentBytes(collectionId: period)) { error in
            XCTAssertEqual(error as? CollectionParseError, .invalidCollectionId(period))
        }
        XCTAssertThrowsError(try CollectionParse.parentBytes(collectionId: "_1")) { error in
            XCTAssertEqual(error as? CollectionParseError, .invalidCollectionId("_1"))
        }
        XCTAssertNil(CollectionParse.absoluteCollectionId(period))
        XCTAssertNil(CollectionParse.absoluteCollectionId("_1"))
    }

    func test_collectionIdNormalizesRelativeGoVector() {
        let id = CollectionParse.collectionId(
            mapData: [
                "type": "ord",
                "subType": "collectionItem",
                "subTypeData": "{\"collectionId\":\"_1\",\"mintNumber\":7}",
            ],
            itemOutpoint: "\(goTxid).3"
        )
        XCTAssertEqual(id, "\(goTxid)_1")
    }

    func test_collectionIdPassesAbsoluteGoVector() {
        let id = CollectionParse.collectionId(
            mapData: [
                "type": "ord",
                "subType": "collectionItem",
                "subTypeData": "{\"collectionId\":\"\(absID)\"}",
            ],
            itemOutpoint: nil
        )
        XCTAssertEqual(id, absID)
    }

    func test_collectionIdSkipsCollectionSubtype() {
        XCTAssertNil(
            CollectionParse.collectionId(
                mapData: [
                    "type": "ord",
                    "subType": "collection",
                    "name": "Demo",
                ],
                itemOutpoint: nil
            )
        )
    }

    func test_collectionIdIgnoresTopLevelCollectionId() {
        XCTAssertNil(
            CollectionParse.collectionId(
                mapData: [
                    "type": "ord",
                    "subType": "collectionItem",
                    "collectionId": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0",
                ],
                itemOutpoint: nil
            )
        )
    }

    func test_collectionIdRejectsEmptyOrInvalidSubTypeData() {
        XCTAssertNil(
            CollectionParse.collectionId(
                mapData: ["subType": "collectionItem"],
                itemOutpoint: nil
            )
        )
        XCTAssertNil(
            CollectionParse.collectionId(
                mapData: ["subType": "collectionItem", "subTypeData": ""],
                itemOutpoint: nil
            )
        )
        XCTAssertNil(
            CollectionParse.collectionId(
                mapData: ["subType": "collectionItem", "subTypeData": "not-json"],
                itemOutpoint: nil
            )
        )
        XCTAssertNil(
            CollectionParse.collectionId(
                mapData: ["subType": "collectionItem", "subTypeData": "{\"collectionId\":\"\"}"],
                itemOutpoint: nil
            )
        )
    }

    func test_normalizeRelativeCollectionIdMatchesGo() {
        let ffff = String(repeating: "f", count: 64)
        XCTAssertEqual(
            CollectionParse.normalizeRelativeCollectionId("_2", itemOutpoint: "\(ffff).5"),
            "\(ffff)_2"
        )
        let absolute = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef_0"
        XCTAssertEqual(
            CollectionParse.normalizeRelativeCollectionId(absolute, itemOutpoint: "\(ffff).5"),
            absolute
        )
        XCTAssertEqual(
            CollectionParse.normalizeRelativeCollectionId("_2", itemOutpoint: nil),
            "_2"
        )
        XCTAssertEqual(
            CollectionParse.normalizeRelativeCollectionId("_x", itemOutpoint: "\(ffff).5"),
            "_x"
        )
    }

    func test_collectionItemMapPairOrderMatchesTypeScriptMetadata() {
        let data = CollectionItemSubTypeData(
            collectionId: itemCollectionId,
            mintNumber: 1,
            rank: 2,
            rarityLabel: "rare",
            traits: [CollectionItemTrait(name: "Color", value: "Blue")]
        )
        let pairs = CollectionMap.collectionItem(name: "Item", data: data)
        let expectedJSON =
            "{\"collectionId\":\"\(itemCollectionId)\",\"mintNumber\":1,\"rank\":2,\"rarityLabel\":\"rare\",\"traits\":[{\"name\":\"Color\",\"value\":\"Blue\"}]}"
        XCTAssertEqual(
            pairs.map { [$0.0, $0.1] },
            [
                ["app", "1sat-wallet"],
                ["type", "ord"],
                ["name", "Item"],
                ["subType", "collectionItem"],
                ["subTypeData", expectedJSON],
            ]
        )
    }

    func test_collectionMapEncodesEmptyDefaultsAndOmitsEmptyRoyalties() {
        let data = CollectionSubTypeData(description: "Collection root", quantity: 2)
        let pairs = CollectionMap.collection(name: "Root", data: data)
        XCTAssertEqual(pairs.map(\.0), ["app", "type", "name", "subType", "subTypeData"])
        XCTAssertEqual(
            pairs[4].1,
            "{\"description\":\"Collection root\",\"quantity\":2,\"rarityLabels\":[],\"traits\":{}}"
        )

        let withRoyalties = CollectionMap.collection(
            name: "Root",
            data: data,
            royalties: [
                Royalty(
                    type: .address,
                    destination: ActionVectors.payAddress,
                    percentage: "0.02"
                ),
            ]
        )
        XCTAssertEqual(
            withRoyalties.map(\.0),
            ["app", "type", "name", "subType", "subTypeData", "royalties"]
        )
        XCTAssertEqual(
            withRoyalties[5].1,
            "[{\"type\":\"address\",\"destination\":\"\(ActionVectors.payAddress)\",\"percentage\":\"0.02\"}]"
        )
    }

    func test_validateReturnsPinnedStrings() {
        XCTAssertEqual(
            CollectionParse.validate(CollectionSubTypeData(description: "", quantity: 2)),
            "Collection description is required"
        )
        XCTAssertEqual(
            CollectionParse.validate(CollectionSubTypeData(description: "Root", quantity: 0)),
            "Collection quantity is required"
        )
        XCTAssertNil(
            CollectionParse.validate(CollectionSubTypeData(description: "Root", quantity: 2))
        )

        XCTAssertEqual(
            CollectionParse.validate(CollectionItemSubTypeData(collectionId: "")),
            "Collection id is required"
        )
        XCTAssertEqual(
            CollectionParse.validate(
                CollectionItemSubTypeData(collectionId: "\(originTxid).0")
            ),
            "Collection id must be a valid outpoint"
        )
        XCTAssertEqual(
            CollectionParse.validate(CollectionItemSubTypeData(collectionId: "abc_1")),
            "Collection id must contain a valid txid"
        )
        XCTAssertEqual(
            CollectionParse.validate(
                CollectionItemSubTypeData(collectionId: "\(originTxid)_x")
            ),
            "Collection id must contain a valid vout"
        )
        XCTAssertNil(
            CollectionParse.validate(
                CollectionItemSubTypeData(
                    collectionId: itemCollectionId,
                    mintNumber: 1,
                    rank: 2,
                    rarityLabel: "rare",
                    traits: [CollectionItemTrait(name: "Color", value: "Blue")]
                )
            )
        )
    }

    func test_groupSeparatesParentsItemsAndStandalone() throws {
        let parent = try walletOutput(
            outpoint: "\(originTxid).0",
            tags: ["type:image/png", CollectionParse.parentTag]
        )
        let itemA = try walletOutput(
            outpoint: "\(originTxid).1",
            tags: [
                "type:image/png",
                CollectionParse.itemTag,
                "\(CollectionParse.collectionIdTagPrefix)\(itemCollectionId)",
            ]
        )
        let itemB = try walletOutput(
            outpoint: "\(originTxid).2",
            tags: [
                "type:image/png",
                CollectionParse.itemTag,
                "\(CollectionParse.collectionIdTagPrefix)\(itemCollectionId)",
            ]
        )
        let lone = try walletOutput(
            outpoint: "\(originTxid).3",
            tags: ["type:image/png"]
        )
        let idWithoutItem = try walletOutput(
            outpoint: "\(originTxid).4",
            tags: ["\(CollectionParse.collectionIdTagPrefix)\(itemCollectionId)"]
        )
        let itemWithoutId = try walletOutput(
            outpoint: "\(originTxid).5",
            tags: [CollectionParse.itemTag]
        )

        let grouping = CollectionParse.group(
            ordinalOutputs: [parent, itemA, itemB, lone, idWithoutItem, itemWithoutId]
        )
        XCTAssertEqual(grouping.parents, [parent])
        XCTAssertEqual(grouping.itemsByCollectionId[itemCollectionId], [itemA, itemB])
        XCTAssertEqual(grouping.itemsByCollectionId.count, 1)
        XCTAssertEqual(grouping.standalone, [lone, idWithoutItem, itemWithoutId])
        XCTAssertEqual(CollectionParse.collectionId(fromOrigin: "\(originTxid).0"), "\(originTxid)_0")
    }

    func test_groupReadsCanonicalAndHistoricalCollectionTags() throws {
        let canonical = try walletOutput(
            outpoint: "\(originTxid).1",
            tags: [CollectionParse.itemTag, "\(CollectionParse.collectionTagPrefix)\(itemCollectionId)"]
        )
        let historical = try walletOutput(
            outpoint: "\(originTxid).2",
            tags: [CollectionParse.itemTag, "\(CollectionParse.collectionIdTagPrefix)\(itemCollectionId)"]
        )

        XCTAssertEqual(
            CollectionParse.group(ordinalOutputs: [canonical, historical])
                .itemsByCollectionId[itemCollectionId],
            [canonical, historical]
        )
    }

    func test_groupPrefersCanonicalCollectionTagWhenBothExist() throws {
        let historicalId = String(repeating: "c", count: 64) + "_2"
        let output = try walletOutput(
            outpoint: "\(originTxid).1",
            tags: [
                CollectionParse.itemTag,
                "\(CollectionParse.collectionIdTagPrefix)\(historicalId)",
                "\(CollectionParse.collectionTagPrefix)\(itemCollectionId)",
            ]
        )

        let grouping = CollectionParse.group(ordinalOutputs: [output])
        XCTAssertEqual(grouping.itemsByCollectionId[itemCollectionId], [output])
        XCTAssertNil(grouping.itemsByCollectionId[historicalId])
    }

    func test_legacyNameTagMovesToCustomInstructionsNameWithoutReemitting() {
        let resolved = Ordinals.resolveOrdinalTags(
            outpoint: "\(originTxid).0",
            tags: ["type:image/png", "origin", "name:Legacy Ape"]
        )

        XCTAssertEqual(resolved.name, "Legacy Ape")
        XCTAssertFalse(resolved.tags.contains { $0.hasPrefix("name:") })
    }

    func test_resolveOrdinalTagsMatchesCanonicalTypeAndOriginVector() {
        let resolved = Ordinals.resolveOrdinalTags(
            outpoint: "\(originTxid).0",
            tags: [
                "type:image",
                "type:image/png; charset=utf-8",
                "type:application/json",
                "origin:\(originTxid).7",
            ]
        )

        XCTAssertEqual(resolved.tags, ["type:image/png", "origin:\(originTxid)_7"])
    }

    func test_resolveOrdinalTagsDoesNotInventMissingOrigin() {
        let resolved = Ordinals.resolveOrdinalTags(
            outpoint: "\(originTxid).0",
            tags: nil,
            contentType: "image/png"
        )

        XCTAssertEqual(resolved.tags, ["type:image/png"])
    }

    private func walletOutput(outpoint: String, tags: [String]) throws -> WalletOutput {
        try WalletOutput(
            satoshis: 1,
            spendable: true,
            tags: tags,
            outpoint: try Outpoint(outpoint)
        )
    }
}
