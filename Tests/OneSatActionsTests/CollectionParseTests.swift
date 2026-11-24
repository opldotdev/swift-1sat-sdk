import BSVCore
import BSVTransaction
import BSVWallet
import OneSatClient
import ToolboxCore
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
        // The id tag is membership; the subType tag alone is not.
        XCTAssertEqual(grouping.itemsByCollectionId[itemCollectionId], [itemA, itemB, idWithoutItem])
        XCTAssertEqual(grouping.itemsByCollectionId.count, 1)
        XCTAssertEqual(grouping.collectionIds, [itemCollectionId])
        XCTAssertEqual(grouping.standalone, [lone, itemWithoutId])
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

    func test_groupReadsLowercasedTagsStorageNowHoldsAlongsideCamelCaseRows() throws {
        let otherCollectionId = String(repeating: "d", count: 64) + "_0"
        let lowerParent = try walletOutput(
            outpoint: "\(originTxid).0",
            tags: ["type:image/png", "origin", "subtype:collection"]
        )
        let camelParent = try walletOutput(
            outpoint: "\(originTxid).6",
            tags: ["type:image/png", "origin", "subType:collection"]
        )
        let lowerItem = try walletOutput(
            outpoint: "\(originTxid).1",
            tags: ["type:image/png", "subtype:collectionitem", "collection:\(itemCollectionId)"]
        )
        let camelItem = try walletOutput(
            outpoint: "\(originTxid).2",
            tags: ["type:image/png", "subType:collectionItem", "collection:\(itemCollectionId)"]
        )
        let lowerHistoricalItem = try walletOutput(
            outpoint: "\(originTxid).3",
            tags: ["subtype:collectionitem", "collectionid:\(itemCollectionId)"]
        )
        let camelHistoricalItem = try walletOutput(
            outpoint: "\(originTxid).4",
            tags: ["subType:collectionItem", "collectionId:\(otherCollectionId)"]
        )
        let historicalOnly = try walletOutput(
            outpoint: "\(originTxid).5",
            tags: ["type:image/png", "collectionid:\(itemCollectionId)"]
        )
        let lone = try walletOutput(
            outpoint: "\(originTxid).7",
            tags: ["type:image/png"]
        )

        let grouping = CollectionParse.group(ordinalOutputs: [
            lowerParent, camelParent, lowerItem, camelItem, lowerHistoricalItem, camelHistoricalItem,
            historicalOnly, lone,
        ])
        XCTAssertEqual(grouping.parents, [lowerParent, camelParent])
        XCTAssertEqual(
            grouping.itemsByCollectionId[itemCollectionId],
            [lowerItem, camelItem, lowerHistoricalItem, historicalOnly]
        )
        XCTAssertEqual(grouping.itemsByCollectionId[otherCollectionId], [camelHistoricalItem])
        XCTAssertEqual(grouping.itemsByCollectionId.count, 2)
        XCTAssertEqual(grouping.standalone, [lone])
    }

    func test_groupPrefersCanonicalCollectionTagWhenBothExistLowercased() throws {
        let historicalId = String(repeating: "c", count: 64) + "_2"
        let output = try walletOutput(
            outpoint: "\(originTxid).1",
            tags: [
                "subtype:collectionitem",
                "collectionid:\(historicalId)",
                "collection:\(itemCollectionId)",
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

    /// The tag reads behind `resolveOrdinalTags`: the origin as written (a bare `origin` is the
    /// outpoint itself, the first origin tag wins) and the most specific `type:`.
    func test_tagOriginAndContentTypeReadTheTagsAsResolveDoes() {
        let outpoint = "\(originTxid).0"
        XCTAssertEqual(Ordinals.tagOrigin(outpoint: outpoint, tags: ["origin"]), outpoint)
        XCTAssertEqual(
            Ordinals.tagOrigin(outpoint: outpoint, tags: ["name:x", "origin:\(originTxid).7", "origin"]),
            "\(originTxid).7"
        )
        XCTAssertNil(Ordinals.tagOrigin(outpoint: outpoint, tags: ["type:image/png"]))
        XCTAssertNil(Ordinals.tagOrigin(outpoint: outpoint, tags: nil))

        let tags = ["type:image", "type:image/png; charset=utf-8", "type:application/json"]
        XCTAssertEqual(Ordinals.tagContentType(tags), "image/png")
        XCTAssertEqual(Ordinals.tagContentType(["type:text/plain", "type:image/png"]), "text/plain")
        XCTAssertEqual(Ordinals.tagContentType(tags, contentType: "text/html; charset=utf-8"), "text/html")
        XCTAssertEqual(Ordinals.tagContentType(["type:image/png"], contentType: "image"), "image/png")
        XCTAssertNil(Ordinals.tagContentType(["type:", "origin"]))
    }

    func test_resolveOrdinalTagsDoesNotInventMissingOrigin() {
        let resolved = Ordinals.resolveOrdinalTags(
            outpoint: "\(originTxid).0",
            tags: nil,
            contentType: "image/png"
        )

        XCTAssertEqual(resolved.tags, ["type:image/png"])
    }

    /// BRC-147 sync tags: `origin:`, `collection:`, `type:` and no subType tag (Pixel Foxes as
    /// received from another wallet).
    func test_groupTreatsCollectionTagAloneAsMembership() throws {
        let foxes = try (1...3).map { index in
            try walletOutput(
                outpoint: "\(originTxid).\(index)",
                tags: ["origin:\(originTxid)_\(index)", "collection:\(itemCollectionId)", "type:image/png"]
            )
        }
        let grouping = CollectionParse.group(ordinalOutputs: foxes)
        XCTAssertEqual(grouping.itemsByCollectionId[itemCollectionId], foxes)
        XCTAssertEqual(grouping.collectionIds, [itemCollectionId])
        XCTAssertTrue(grouping.parents.isEmpty)
        XCTAssertTrue(grouping.standalone.isEmpty)
    }

    func test_groupRecognisesUntaggedParentByOrigin() throws {
        let parentTxid = String(repeating: "b", count: 64)
        let tagged = try walletOutput(
            outpoint: "\(String(repeating: "e", count: 64)).0",
            tags: ["origin:\(parentTxid)_1", "type:image/png"]
        )
        let bare = try walletOutput(outpoint: "\(parentTxid).1", tags: ["origin"])
        let dotted = try walletOutput(
            outpoint: "\(String(repeating: "f", count: 64)).2",
            tags: ["origin:\(parentTxid).1"]
        )
        let item = try walletOutput(
            outpoint: "\(originTxid).1",
            tags: ["collection:\(itemCollectionId)"]
        )
        let grouping = CollectionParse.group(ordinalOutputs: [tagged, bare, dotted, item])
        XCTAssertEqual(grouping.parents, [tagged, bare, dotted])
        XCTAssertEqual(grouping.itemsByCollectionId[itemCollectionId], [item])
        XCTAssertTrue(grouping.standalone.isEmpty)
    }

    func test_groupLeavesUnreferencedUntaggedOutputStandalone() throws {
        let other = try walletOutput(
            outpoint: "\(String(repeating: "b", count: 64)).1",
            tags: ["origin", "type:image/png"]
        )
        let grouping = CollectionParse.group(ordinalOutputs: [other])
        XCTAssertEqual(grouping.standalone, [other])
        XCTAssertTrue(grouping.parents.isEmpty)
    }

    func test_groupKeepsNonOutpointCollectionValuesStandalone() throws {
        let named = try walletOutput(outpoint: "\(originTxid).1", tags: ["collection:pixel foxes"])
        let grouping = CollectionParse.group(ordinalOutputs: [named])
        XCTAssertEqual(grouping.standalone, [named])
        XCTAssertTrue(grouping.itemsByCollectionId.isEmpty)
    }

    func test_groupResolvesRelativeCollectionIdAgainstOriginTxid() throws {
        let item = try walletOutput(
            outpoint: "\(String(repeating: "c", count: 64)).4",
            tags: ["origin:\(originTxid)_3", "collection:_0"]
        )
        XCTAssertEqual(
            CollectionParse.memberCollectionId(tags: item.tags ?? [], origin: CollectionParse.origin(of: item)),
            "\(originTxid)_0"
        )
        XCTAssertEqual(CollectionParse.group(ordinalOutputs: [item]).collectionIds, ["\(originTxid)_0"])
    }

    func test_groupNormalisesIdFormAndCase() throws {
        let upper = String(repeating: "B", count: 64)
        let dotted = try walletOutput(outpoint: "\(originTxid).1", tags: ["collection:\(upper).1"])
        let underscore = try walletOutput(outpoint: "\(originTxid).2", tags: ["collection:\(itemCollectionId)"])
        let grouping = CollectionParse.group(ordinalOutputs: [dotted, underscore])
        XCTAssertEqual(grouping.itemsByCollectionId[itemCollectionId], [dotted, underscore])
    }

    func test_groupOrdersCollectionIdsByFirstAppearance() throws {
        let ids = ["d", "b", "c"].map { String(repeating: $0, count: 64) + "_0" }
        let outputs = try ids.enumerated().flatMap { index, id in
            try (0..<2).map { copy in
                try walletOutput(outpoint: "\(originTxid).\(index * 2 + copy)", tags: ["collection:\(id)"])
            }
        }
        for _ in 0..<5 {
            XCTAssertEqual(CollectionParse.group(ordinalOutputs: outputs).collectionIds, ids)
        }
    }

    func test_groupItemTaggedOutputWithParentTagStaysParent() throws {
        let output = try walletOutput(
            outpoint: "\(originTxid).0",
            tags: [CollectionParse.parentTag, "collection:\(itemCollectionId)"]
        )
        let grouping = CollectionParse.group(ordinalOutputs: [output])
        XCTAssertEqual(grouping.parents, [output])
        XCTAssertTrue(grouping.itemsByCollectionId.isEmpty)
    }

    /// `GET /1sat/ordfs/metadata/549ce573…_81` as served, byte for byte (Pixel Foxes #2043685).
    private static let pixelFoxMetadataJSON = #"""
    {"contentLength":2566,"contentType":"image/png","map":{"app":"Bubblemint","name":"Pixel Foxes #2043685","subType":"collectionItem","subTypeData":"{\"collectionId\":\"1611d956f397caa80b56bc148b4bce87b54f39b234aeca4668b4d5a7785eb9fa_0\",\"traits\":[{\"name\":\"background\",\"value\":\"lemon\"},{\"name\":\"fox\",\"value\":\"Arctic Fox\"},{\"name\":\"body\",\"value\":\"Red Shirt\"},{\"name\":\"mouth\",\"value\":\"Mouth\"},{\"name\":\"head item\",\"value\":\"Gold Durag\"},{\"name\":\"eyes\",\"value\":\"Down to the Right\"},{\"name\":\"item\",\"value\":\"none\"}]}","type":"ord"},"origin":"549ce573ca22dbc682dabe6c0311e55afe93651de3aadcaa9d2d2fd83c227966.81","outpoint":"549ce573ca22dbc682dabe6c0311e55afe93651de3aadcaa9d2d2fd83c227966.81","sequence":0}
    """#
    private static let pixelFoxesCollectionId =
        "1611d956f397caa80b56bc148b4bce87b54f39b234aeca4668b4d5a7785eb9fa_0"
    private static let pixelFoxCurrentOutpoint =
        "092af97dd49686f205348007dace0e8c64ed5cc8dffa6d239ebba0a54600d344.1"

    func test_livePixelFoxGroupsUnderItsCollectionWithItsParentAndTraits() throws {
        let metadata = try JSONDecoder().decode(
            OrdfsMetadata.self,
            from: Data(Self.pixelFoxMetadataJSON.utf8)
        )
        let tags = OrdinalTags.fromMetadata(
            metadata,
            fallbackOrigin: Self.pixelFoxCurrentOutpoint
        )
        XCTAssertEqual(tags, [
            "origin:549ce573ca22dbc682dabe6c0311e55afe93651de3aadcaa9d2d2fd83c227966_81",
            "collection:\(Self.pixelFoxesCollectionId)",
            "app:Bubblemint",
            "type:image/png",
        ])
        let fox = try walletOutput(outpoint: Self.pixelFoxCurrentOutpoint, tags: tags)
        let parentTags = OrdinalTags.fromMetadata(
            origin: "1611d956f397caa80b56bc148b4bce87b54f39b234aeca4668b4d5a7785eb9fa.0",
            contentType: "image/png",
            map: ["app": "Bubblemint", "name": "Pixel Foxes", "subType": "collection", "type": "ord"]
        )
        let parent = try walletOutput(
            outpoint: "1611d956f397caa80b56bc148b4bce87b54f39b234aeca4668b4d5a7785eb9fa.0",
            tags: parentTags
        )

        let grouping = CollectionParse.group(ordinalOutputs: [fox, parent])
        XCTAssertEqual(grouping.collectionIds, [Self.pixelFoxesCollectionId])
        XCTAssertEqual(grouping.itemsByCollectionId[Self.pixelFoxesCollectionId], [fox])
        XCTAssertEqual(grouping.parents, [parent])
        XCTAssertTrue(grouping.standalone.isEmpty)

        let traits = CollectionParse.itemTraits(fromMap: metadata.map)
        XCTAssertEqual(traits.map(\.name), [
            "background", "fox", "body", "mouth", "head item", "eyes", "item",
        ])
        XCTAssertEqual(traits.map(\.value), [
            "lemon", "Arctic Fox", "Red Shirt", "Mouth", "Gold Durag", "Down to the Right", "none",
        ])
        XCTAssertTrue(traits.allSatisfy { $0.rarityLabel == nil && $0.occurancePercentrage == nil })
    }

    func test_itemTraitsReadsObjectSubTypeDataAndKeepsOptionalStrings() {
        let traits = CollectionParse.itemTraits(fromMap: [
            "subType": "collectionItem",
            "subTypeData": .object([
                "collectionId": "_0",
                "traits": .array([
                    .object([
                        "name": "Color",
                        "value": "Blue",
                        "rarityLabel": "rare",
                        "occurancePercentrage": "12.5",
                    ]),
                    .object(["name": "Size", "value": "L", "rarityLabel": 3]),
                ]),
            ]),
        ])
        XCTAssertEqual(traits, [
            CollectionItemTrait(name: "Color", value: "Blue", rarityLabel: "rare", occurancePercentrage: "12.5"),
            CollectionItemTrait(name: "Size", value: "L"),
        ])
    }

    func test_itemTraitsKeepsNumberAndBoolValuesAsJSONText() {
        let traits = CollectionParse.itemTraits(fromMap: [
            "subTypeData": #"{"traits":[{"name":"Level","value":7},{"name":"Speed","value":1.5},{"name":"Shiny","value":true}]}"#,
        ])
        XCTAssertEqual(traits.map(\.value), ["7", "1.5", "true"])
    }

    func test_itemTraitsSkipsEntriesWithoutNameOrValue() {
        let traits = CollectionParse.itemTraits(fromMap: [
            "subTypeData": #"{"traits":[{"name":"","value":"x"},{"value":"y"},{"name":"NoValue"},{"name":"Null","value":null},{"name":"Nested","value":{"a":1}},"loose",{"name":"Kept","value":""}]}"#,
        ])
        XCTAssertEqual(traits, [CollectionItemTrait(name: "Kept", value: "")])
    }

    func test_itemTraitsIsEmptyWithoutTraits() {
        XCTAssertEqual(CollectionParse.itemTraits(fromMap: nil), [])
        XCTAssertEqual(CollectionParse.itemTraits(fromMap: ["name": "Lone"]), [])
        XCTAssertEqual(CollectionParse.itemTraits(fromMap: ["subTypeData": "not-json"]), [])
        XCTAssertEqual(CollectionParse.itemTraits(fromMap: ["subTypeData": #"{"collectionId":"_0"}"#]), [])
        XCTAssertEqual(CollectionParse.itemTraits(fromMap: ["subTypeData": #"{"traits":{"a":"b"}}"#]), [])
    }

    /// `GET /1sat/ordfs/metadata/1611d956…_0`, the Pixel Foxes parent, as served.
    private static let pixelFoxesParentMetadataJSON = #"""
    {"contentLength":1594,"contentType":"image/png","map":{"app":"RareDropper","name":"Pixel Foxes","royalties":"[{\"type\":\"address\",\"destination\":\"1HERMQcdFQNTFShD2mpt81McxX9kPQ9AEP\",\"percentage\":\"0.03\"}]","subType":"collection","subTypeData":"{\"description\":\"10,000,000 pixel foxes on-chain forever\"}","type":"ord"},"origin":"1611d956f397caa80b56bc148b4bce87b54f39b234aeca4668b4d5a7785eb9fa.0","outpoint":"1611d956f397caa80b56bc148b4bce87b54f39b234aeca4668b4d5a7785eb9fa.0","sequence":0}
    """#

    func test_livePixelFoxItemDetailsHaveOnlyTraits() throws {
        let metadata = try JSONDecoder().decode(OrdfsMetadata.self, from: Data(Self.pixelFoxMetadataJSON.utf8))
        let details = CollectionParse.itemDetails(fromMap: metadata.map)
        XCTAssertEqual(details.traits.count, 7)
        XCTAssertEqual(details.traits.first, CollectionItemTrait(name: "background", value: "lemon"))
        XCTAssertNil(details.mintNumber)
        XCTAssertNil(details.rank)
        XCTAssertNil(details.rarityLabel)
        XCTAssertFalse(details.isEmpty)
    }

    func test_livePixelFoxesParentDetailsHaveOnlyADescription() throws {
        let metadata = try JSONDecoder().decode(
            OrdfsMetadata.self,
            from: Data(Self.pixelFoxesParentMetadataJSON.utf8)
        )
        XCTAssertEqual(
            CollectionParse.collectionDetails(fromMap: metadata.map),
            CollectionDetails(description: "10,000,000 pixel foxes on-chain forever")
        )
    }

    /// The spec's shape: `rarityLabels` and `traits` each stringified inside stringified
    /// `subTypeData`, members in an order that is not alphabetical.
    func test_collectionDetailsReadsSpecShapedParentInOrder() {
        let rarity = #"{"legendary":"1.00","common":"96.00","rare":"3.00"}"#
        let traits = #"{"eyes":{"values":["blue","green"],"occurancePercentages":["60.00","40.00"]},"background":{"values":["red","blue","gold"],"occurancePercentages":["50.00","45.00","5.00"]}}"#
        let subTypeData = try! String(
            data: JSONSerialization.data(withJSONObject: [
                "description": "Spec owls",
                "quantity": "300",
                "rarityLabels": rarity,
                "traits": traits,
            ]),
            encoding: .utf8
        )!
        let details = CollectionParse.collectionDetails(fromMap: [
            "subType": "collection",
            "subTypeData": .string(subTypeData),
        ])
        XCTAssertEqual(details.description, "Spec owls")
        XCTAssertEqual(details.quantity, 300)
        XCTAssertEqual(details.quantityText, "300")
        XCTAssertEqual(details.rarityLabels, [
            RarityLabelEntry(key: "legendary", value: "1.00"),
            RarityLabelEntry(key: "common", value: "96.00"),
            RarityLabelEntry(key: "rare", value: "3.00"),
        ])
        XCTAssertEqual(details.traits, [
            CollectionTraitEntry(
                name: "eyes",
                trait: CollectionTrait(values: ["blue", "green"], occurancePercentages: ["60.00", "40.00"])
            ),
            CollectionTraitEntry(
                name: "background",
                trait: CollectionTrait(
                    values: ["red", "blue", "gold"],
                    occurancePercentages: ["50.00", "45.00", "5.00"]
                )
            ),
        ])
    }

    /// Nested objects instead of text, TS's array of rarity objects, a numeric quantity and one
    /// that is not a whole number.
    func test_collectionDetailsAcceptsObjectsArraysAndLooseQuantities() {
        let nested = CollectionParse.collectionDetails(fromMap: [
            "subTypeData": #"{"description":"Owls","quantity":12,"rarityLabels":[{"common":"90"},{"rare":"10"}],"traits":{"hat":{"values":["cap"],"occurancePercentages":["100"]},"empty":{"values":[]}}}"#,
        ])
        XCTAssertEqual(nested.quantity, 12)
        XCTAssertEqual(nested.quantityText, "12")
        XCTAssertEqual(nested.rarityLabels.map(\.key), ["common", "rare"])
        XCTAssertEqual(nested.traits.map(\.name), ["hat"])

        let loose = CollectionParse.collectionDetails(fromMap: [
            "subTypeData": .object(["description": "Owls", "quantity": "10,000,000"]),
        ])
        XCTAssertNil(loose.quantity)
        XCTAssertEqual(loose.quantityText, "10,000,000")

        XCTAssertEqual(CollectionParse.collectionDetails(fromMap: nil), CollectionDetails())
        XCTAssertEqual(CollectionParse.collectionDetails(fromMap: ["subTypeData": "not-json"]), CollectionDetails())
    }

    func test_itemDetailsReadsMintNumberRankRarityAndBothPercentSpellings() {
        let details = CollectionParse.itemDetails(fromMap: [
            "subType": "collectionItem",
            "subTypeData": #"{"collectionId":"_0","mintNumber":42,"rank":"3","rarityLabel":"rare","traits":[{"name":"eyes","value":"blue","occurrencePercent":"60.00"},{"name":"hat","value":"cap","occurancePercentrage":"5.00"},{"name":"bg","value":"red","occurrencePercent":12.5}]}"#,
        ])
        XCTAssertEqual(details, CollectionItemDetails(
            traits: [
                CollectionItemTrait(name: "eyes", value: "blue", occurancePercentrage: "60.00"),
                CollectionItemTrait(name: "hat", value: "cap", occurancePercentrage: "5.00"),
                CollectionItemTrait(name: "bg", value: "red", occurancePercentrage: "12.5"),
            ],
            mintNumber: 42,
            rank: 3,
            rarityLabel: "rare"
        ))
        XCTAssertTrue(CollectionParse.itemDetails(fromMap: ["subTypeData": #"{"mintNumber":1.5}"#]).isEmpty)
    }

    func test_collectionMapJSONReadsEscapesAndRejectsBrokenText() {
        XCTAssertEqual(
            CollectionMapJSON.parse(#"{"b":"é\"x","a":[1,true,null]}"#),
            .object([("b", .string("é\"x")), ("a", .array([.number(1), .bool(true), .null]))])
        )
        XCTAssertNil(CollectionMapJSON.parse(#"{"a":1"#))
        XCTAssertNil(CollectionMapJSON.parse(#"{"a":1} x"#))
        XCTAssertNil(CollectionMapJSON.parse(String(repeating: "[", count: 70) + String(repeating: "]", count: 70)))
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
