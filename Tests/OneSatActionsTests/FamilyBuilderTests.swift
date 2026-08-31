import Foundation
import BSVCore
import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet
import OneSatTemplates
import ToolboxActions
import ToolboxAuth
import ToolboxStorage
import ToolboxStorageClient
import XCTest
@testable import OneSatActions

final class FamilyBuilderTests: XCTestCase {
    func test_transferRefusesBsv20AndMissingDestination() throws {
        let identity = try ActionVectors.identity()
        let ctx = try dummyContext(identity: identity)
        let ordinal = try walletOutput(
            tags: ["type:application/bsv-20", "id:abc_0"],
            instructions: try CustomInstructions(keyID: ActionVectors.outpoint).encoded()
        )
        XCTAssertThrowsError(
            try Ordinals.buildTransfer(
                ctx,
                Ordinals.TransferRequest(
                    transfers: [Ordinals.TransferItem(ordinal: ordinal, address: ActionVectors.payAddress)]
                )
            )
        ) { error in
            XCTAssertEqual(
                (error as? OneSatActionError)?.wireMessage.contains("BSV-20"),
                true
            )
        }
        let plain = try walletOutput(
            tags: ["type:image/png", "id:abc_0"],
            instructions: try CustomInstructions(keyID: ActionVectors.outpoint).encoded()
        )
        XCTAssertThrowsError(
            try Ordinals.buildTransfer(
                ctx,
                Ordinals.TransferRequest(transfers: [Ordinals.TransferItem(ordinal: plain)])
            )
        )
    }

    func test_transferBuilderEmitsOneSatOutputAndInputLabel() throws {
        let identity = try ActionVectors.identity()
        let ctx = try dummyContext(identity: identity)
        let ordinal = try walletOutput(
            tags: ["type:image/png", "origin:\(ActionVectors.outpoint)", "id:deadbeef_0"],
            instructions: try CustomInstructions(keyID: ActionVectors.outpoint).encoded()
        )
        let prepared = try Ordinals.buildTransfer(
            ctx,
            Ordinals.TransferRequest(
                transfers: [
                    Ordinals.TransferItem(ordinal: ordinal, address: ActionVectors.payAddress),
                ]
            )
        )
        XCTAssertEqual(prepared.description, "Transfer ordinal")
        XCTAssertEqual(prepared.inputs.count, 1)
        XCTAssertEqual(prepared.outputs.count, 1)
        XCTAssertEqual(prepared.outputs[0].satoshis, 1)
        XCTAssertEqual(prepared.outputs[0].basket, nil)
        XCTAssertEqual(prepared.outputs[0].tags, [])
        XCTAssertEqual(
            prepared.labels,
            [OneSatConstants.inputAssetLabel(basket: OneSatConstants.ordinalsBasket, id: "deadbeef_0")]
        )
        XCTAssertEqual(prepared.signers[0].keyID, ActionVectors.outpoint)
    }

    func test_reinscribeUsesTheSameEnvelopeAsInscribe() throws {
        let identity = try ActionVectors.identity()
        let ctx = try dummyContext(identity: identity)
        let content = Array("Hello, BSV!".utf8)
        let ordinal = try walletOutput(
            tags: ["type:image/png", "origin:\(ActionVectors.outpoint)", "id:deadbeef_0"],
            instructions: try CustomInstructions(keyID: ActionVectors.outpoint).encoded()
        )
        let prepared = try Ordinals.buildTransfer(
            ctx,
            Ordinals.TransferRequest(
                transfers: [
                    Ordinals.TransferItem(
                        ordinal: ordinal,
                        address: ActionVectors.templateAddress,
                        map: [("name", "hello")],
                        inscription: Ordinals.InscriptionPayload(
                            content: content,
                            contentType: "text/plain"
                        )
                    ),
                ]
            )
        )
        XCTAssertEqual(
            Hex.encode(prepared.outputs[0].lockingScript),
            ActionVectors.inscribeP2PKHMapSuffix
        )
        XCTAssertEqual(prepared.outputs[0].tags, [])
    }

    func test_reinscribeSelfKeepsOriginalIdentityTags() throws {
        let identity = try ActionVectors.identity()
        let ctx = try dummyContext(identity: identity)
        let ordinal = try walletOutput(
            tags: ["type:image/png", "origin:\(ActionVectors.outpoint)", "id:deadbeef_0"],
            instructions: try CustomInstructions(keyID: ActionVectors.outpoint).encoded()
        )
        let prepared = try Ordinals.buildTransfer(
            ctx,
            Ordinals.TransferRequest(
                transfers: [
                    Ordinals.TransferItem(
                        ordinal: ordinal,
                        toSelf: true,
                        inscription: Ordinals.InscriptionPayload(
                            content: Array("next".utf8),
                            contentType: "text/plain"
                        )
                    ),
                ]
            )
        )
        XCTAssertEqual(prepared.outputs[0].basket, OneSatConstants.ordinalsBasket)
        XCTAssertTrue(prepared.outputs[0].tags.contains("type:image/png"))
        XCTAssertFalse(prepared.outputs[0].tags.contains("type:text/plain"))
        XCTAssertTrue(prepared.outputs[0].tags.contains {
            $0.hasPrefix("origin:")
        })
        XCTAssertFalse(prepared.outputs[0].tags.contains { $0.hasPrefix("sha256:") })
        let ci = try XCTUnwrap(prepared.outputs[0].customInstructions)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(ci.utf8)) as? [String: Any]
        )
        XCTAssertEqual(
            object["origin"] as? String,
            Bsv21Remittance.formatOrdinalOutpoint(ActionVectors.outpoint)
        )
    }

    func test_reinscribeRejectsEmptyContent() throws {
        let identity = try ActionVectors.identity()
        let ctx = try dummyContext(identity: identity)
        let ordinal = try walletOutput(
            tags: ["type:image/png", "id:deadbeef_0"],
            instructions: try CustomInstructions(keyID: ActionVectors.outpoint).encoded()
        )
        XCTAssertThrowsError(
            try Ordinals.buildTransfer(
                ctx,
                Ordinals.TransferRequest(
                    transfers: [
                        Ordinals.TransferItem(
                            ordinal: ordinal,
                            address: ActionVectors.payAddress,
                            inscription: Ordinals.InscriptionPayload(
                                content: [],
                                contentType: "text/plain"
                            )
                        ),
                    ]
                )
            )
        ) { error in
            XCTAssertEqual(error as? OneSatActionError, .inscriptionContentEmpty)
        }
    }

    func test_sigmaTransferRequiresInscription() throws {
        let identity = try ActionVectors.identity()
        let ctx = try dummyContext(identity: identity)
        let ordinal = try walletOutput(
            tags: ["type:image/png", "id:deadbeef_0"],
            instructions: try CustomInstructions(keyID: ActionVectors.outpoint).encoded()
        )
        XCTAssertThrowsError(
            try Ordinals.buildTransfer(
                ctx,
                Ordinals.TransferRequest(
                    transfers: [
                        Ordinals.TransferItem(
                            ordinal: ordinal,
                            toSelf: true,
                            signWithBAP: true
                        ),
                    ]
                )
            )
        ) { error in
            XCTAssertEqual(error as? OneSatActionError, .signWithBapRequiresInscription)
        }
    }

    func test_inscribePrepareCapsSizeAndSetsBasketTags() throws {
        let identity = try ActionVectors.identity()
        XCTAssertThrowsError(
            try Inscriptions.prepare(
                identity: identity,
                Inscriptions.Request(
                    content: [UInt8](repeating: 1, count: OneSatConstants.maxInscriptionBytes + 1),
                    contentType: "text/plain"
                )
            )
        )
        let prepared = try Inscriptions.prepare(
            identity: identity,
            Inscriptions.Request(
                content: Array("Hello, BSV!".utf8),
                contentType: "text/plain",
                map: [("name", "hello")],
                destination: .address(ActionVectors.templateAddress)
            )
        )
        XCTAssertEqual(
            prepared.tags,
            [
                "type:text/plain",
                "origin",
                "sha256:b194e2edd2e49265f4615e5d95480bad2ad3ca474222c19c87cbdcf98f384762",
            ]
        )
        XCTAssertNil(prepared.customInstructions)
        XCTAssertEqual(prepared.lockingScript.hex, ActionVectors.inscribeP2PKHMapSuffix)
    }

    func test_lockBuilderWritesUntilTagAndLockKey() throws {
        let identity = try ActionVectors.identity()
        let prepared = try Locks.buildLock(
            identity: identity,
            requests: [Locks.Request(satoshis: 1_000, until: 800_000)]
        )
        XCTAssertEqual(prepared.outputs.count, 1)
        XCTAssertEqual(prepared.outputs[0].basket, OneSatConstants.lockBasket)
        XCTAssertEqual(prepared.outputs[0].tags, ["until:800000"])
        XCTAssertEqual(
            prepared.outputs[0].customInstructions,
            try CustomInstructions(keyID: OneSatConstants.lockKeyID).encoded()
        )
        XCTAssertEqual(prepared.description, "Lock BSV in 1 output(s)")
    }

    func test_unlockBuilderSetsSequenceZeroAndLockTime() throws {
        let output = try walletOutput(
            tags: ["until:100", "id:lock_0"],
            instructions: try CustomInstructions(keyID: OneSatConstants.lockKeyID).encoded()
        )
        let matured = try Locks.maturedLocks(outputs: [output], currentHeight: 100)
        let built = try Locks.buildUnlock(matured: matured)
        XCTAssertEqual(built.lockTime, 100)
        XCTAssertEqual(built.inputs[0].sequenceNumber, 0)
        XCTAssertEqual(
            built.labels,
            [OneSatConstants.inputAssetLabel(basket: OneSatConstants.lockBasket, id: "lock_0")]
        )
        XCTAssertThrowsError(try Locks.maturedLocks(outputs: [output], currentHeight: 99))
    }

    func test_listBuilderUsesOrdLockAndCancelDerivation() throws {
        let identity = try ActionVectors.identity()
        let ctx = try dummyContext(identity: identity)
        let ordinal = try walletOutput(
            tags: ["type:image/png", "id:list_0"],
            instructions: try CustomInstructions(keyID: ActionVectors.outpoint).encoded()
        )
        let prepared = try Ordinals.buildList(
            ctx,
            Ordinals.ListRequest(
                ordinal: ordinal,
                price: 50_000,
                payAddress: ActionVectors.payAddress
            )
        )
        XCTAssertTrue(prepared.outputs[0].tags.contains("ordlock"))
        XCTAssertTrue(prepared.outputs[0].tags.contains("price:50000"))
        XCTAssertEqual(prepared.outputs[0].basket, OneSatConstants.ordinalsBasket)
        XCTAssertEqual(prepared.outputs[0].satoshis, 1)
        let cancel = try Ordinals.cancelAddress(identity: identity, outpoint: ActionVectors.outpoint)
        let expected = try OrdLock.lock(
            cancelAddress: cancel.description,
            payAddress: ActionVectors.payAddress,
            price: 50_000
        )
        XCTAssertEqual(prepared.outputs[0].lockingScript, expected.bytes)
    }

    func test_ordinalSpendBuildersMoveLegacyNamesIntoCustomInstructions() throws {
        let identity = try ActionVectors.identity()
        let ctx = try dummyContext(identity: identity)
        let legacyOnly = try walletOutput(
            tags: ["type:image/png", "name:Legacy Ape", "id:list_0"],
            instructions: try CustomInstructions(keyID: ActionVectors.outpoint).encoded()
        )
        let canonical = try walletOutput(
            tags: ["type:image/png", "name:Legacy Ape", "id:list_0"],
            instructions: try CustomInstructions(
                keyID: ActionVectors.outpoint,
                name: "Canonical Ape"
            ).encoded()
        )
        let partialCanonical = try walletOutput(
            tags: ["name:Legacy Ape"],
            instructions: "{\"name\":\"Canonical Ape\"}"
        )

        XCTAssertEqual(Ordinals.sourceName(from: partialCanonical), "Canonical Ape")

        let transfer = try Ordinals.buildTransfer(
            ctx,
            Ordinals.TransferRequest(
                transfers: [Ordinals.TransferItem(ordinal: legacyOnly, toSelf: true)]
            )
        )
        let listing = try Ordinals.buildList(
            ctx,
            Ordinals.ListRequest(
                ordinal: canonical,
                price: 50_000,
                payAddress: ActionVectors.payAddress
            )
        )
        let cancel = try Ordinals.buildCancel(
            ctx,
            Ordinals.CancelRequest(listing: legacyOnly)
        ).prepared

        XCTAssertEqual(
            try CustomInstructions.parse(XCTUnwrap(transfer.outputs[0].customInstructions)).name,
            "Legacy Ape"
        )
        XCTAssertEqual(
            try CustomInstructions.parse(XCTUnwrap(listing.outputs[0].customInstructions)).name,
            "Canonical Ape"
        )
        XCTAssertEqual(
            try CustomInstructions.parse(XCTUnwrap(cancel.outputs[0].customInstructions)).name,
            "Legacy Ape"
        )
        for output in [transfer.outputs[0], listing.outputs[0], cancel.outputs[0]] {
            XCTAssertFalse(output.tags.contains { $0.hasPrefix("name:") })
        }
    }

    func test_ordinalSweepOutputCarriesResolvedBRC147Metadata() throws {
        let identity = try ActionVectors.identity()
        let ctx = try dummyContext(identity: identity)
        let longName = String(repeating: "a", count: 63) + "😀tail"
        let keyID = Bsv21Remittance.formatOrdinalOutpoint(ActionVectors.outpoint)
        let output = try AssetSweep.ordinalOutput(
            ctx,
            input: AssetSweep.OrdinalInput(
                outpoint: ActionVectors.outpoint,
                satoshis: 1,
                lockingScript: [],
                contentType: "image/png; charset=utf-8",
                origin: ActionVectors.outpoint,
                name: longName,
                key: identity
            ),
            keyID: keyID
        )

        XCTAssertEqual(output.tags, ["type:image/png", "origin:\(keyID)"])
        let instructions = try XCTUnwrap(output.customInstructions)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(instructions.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["protocolID"] as? [AnyHashable], [0, "onesat"])
        XCTAssertEqual(object["keyID"] as? String, keyID)
        XCTAssertEqual(object["counterparty"] as? String, "self")
        XCTAssertEqual(object["origin"] as? String, keyID)
        XCTAssertEqual(object["name"] as? String, String(repeating: "a", count: 63))
    }

    func test_tokenSelectionAndChangeAccounting() throws {
        let identity = try ActionVectors.identity()
        let first = try walletOutput(
            tags: ["bsv21:\(ActionVectors.tokenID)", "amt:80", "id:tok_0"],
            instructions: try CustomInstructions(keyID: "tok-0").encoded()
        )
        let second = try walletOutput(
            tags: ["bsv21:\(ActionVectors.tokenID)", "amt:40", "id:tok_1"],
            instructions: try CustomInstructions(keyID: "tok-1").encoded()
        )
        let selected = try Tokens.selectInputs(
            outputs: [first, second],
            tokenId: ActionVectors.tokenID,
            amount: 100,
            validOutpoints: nil
        )
        XCTAssertEqual(selected.selected.count, 2)
        XCTAssertEqual(selected.totalIn, 120)
        let prepared = try Tokens.buildSend(
            identity: identity,
            tokenId: ActionVectors.tokenID,
            recipients: [
                Tokens.Recipient(amount: 100, destination: .address(ActionVectors.payAddress)),
            ],
            selected: selected.selected,
            totalIn: selected.totalIn,
            details: Bsv21TokenDetails(
                isActive: true,
                feeAddress: ActionVectors.templateAddress,
                feePerOutput: 1_000,
                decimals: 0,
                symbol: "GOLD"
            ),
            changeKeyID: "change-1"
        )
        XCTAssertEqual(prepared.change, 20)
        XCTAssertEqual(prepared.outputs.count, 3)
        XCTAssertEqual(prepared.outputs[1].basket, OneSatConstants.bsv21Basket)
        XCTAssertEqual(prepared.outputs[1].tags, ["bsv21:\(ActionVectors.tokenID)"])
        XCTAssertFalse(prepared.outputs[1].tags.contains { $0.hasPrefix("amt:") })
        let changeCI = Bsv21Remittance.parseCustomInstructions(prepared.outputs[1].customInstructions)
        XCTAssertEqual(changeCI.fields?.amt, "20")
        XCTAssertEqual(changeCI.fields?.id, ActionVectors.tokenID)
        XCTAssertEqual(changeCI.fields?.symbol, "GOLD")
        XCTAssertEqual(prepared.outputs[2].satoshis, 2_000)
        XCTAssertTrue(prepared.labels.contains(OneSatConstants.tokenLabel(ActionVectors.tokenID)))
        XCTAssertEqual(prepared.description, "Send GOLD to 1 recipient")
    }

    func test_tokenSelectionPrefersCIAmountOverTags() throws {
        let ci = Bsv21Remittance.buildCustomInstructions(
            token: Bsv21Remittance.Fields(id: ActionVectors.tokenID, amt: "80"),
            protocolID: try OneSatConstants.p1satProtocolID,
            keyID: "tok-0"
        )
        let output = try walletOutput(
            tags: ["bsv21:\(ActionVectors.tokenID)", "amt:1"],
            instructions: ci
        )
        let selected = try Tokens.selectInputs(
            outputs: [output],
            tokenId: ActionVectors.tokenID,
            amount: 80,
            validOutpoints: nil
        )
        XCTAssertEqual(selected.totalIn, 80)
        XCTAssertEqual(selected.selected[0].amount, 80)
    }

    func test_trackedActionReplacesIdTagsWithoutImplicitDispatchLabel() throws {
        let output = try WalletCreateActionOutput(
            lockingScript: [0x51],
            satoshis: 1,
            outputDescription: "Inscription",
            basket: OneSatConstants.ordinalsBasket,
            tags: ["type:text/plain", "id:stale_9"]
        )
        let tracked = try TrackedAction.applyTracking(
            outputs: [output],
            labels: [],
            actionID: "aabbccdd",
            bypassP1Sat: false
        )
        XCTAssertEqual(tracked.outputs[0].tags, ["type:text/plain", "id:aabbccdd_0"])
        XCTAssertEqual(tracked.labels, [])
    }

    func test_trackedActionRequestCarriesInputBEEF() throws {
        let source = Transaction(
            version: 1,
            inputs: [],
            outputs: [
                TransactionOutput(
                    satoshis: 1,
                    lockingScript: try Script(bytes: [0x51], maximumByteCount: 10_000)
                ),
            ],
            lockTime: 0
        )
        let beef = try BEEF(
            merklePaths: [],
            transactions: [.raw(source)],
            limits: WalletBEEFLimits.standard
        )
        let output = try WalletCreateActionOutput(
            lockingScript: [0x51],
            satoshis: 1,
            outputDescription: "spend",
            tags: []
        )
        let request = try TrackedAction.request(
            description: "external input",
            inputBEEF: beef,
            inputs: [
                WalletCreateActionInput(
                    outpoint: try Outpoint(ActionVectors.outpoint),
                    inputDescription: "external",
                    unlockingScriptLength: 108
                ),
            ],
            outputs: [output],
            actionID: "aabbccdd"
        )
        XCTAssertEqual(
            try request.inputBEEF?.serialized(limits: WalletBEEFLimits.standard),
            try beef.serialized(limits: WalletBEEFLimits.standard)
        )
    }

    func test_tokenSendUsesListOutputsBEEF() async throws {
        let source = Transaction(
            version: 1,
            inputs: [],
            outputs: [
                TransactionOutput(
                    satoshis: 1,
                    lockingScript: try Script(bytes: [0x51], maximumByteCount: 10_000)
                ),
            ],
            lockTime: 0
        )
        let beef = try BEEF(
            merklePaths: [],
            transactions: [.raw(source)],
            limits: WalletBEEFLimits.standard
        )
        let listed = try WalletListOutputsResult(
            totalOutputs: 1,
            beef: beef,
            outputs: [
                try WalletOutput(
                    satoshis: 1,
                    spendable: true,
                    customInstructions: try CustomInstructions(keyID: "tok-0").encoded(),
                    tags: ["bsv21:\(ActionVectors.tokenID)", "amt:80"],
                    outpoint: try Outpoint(ActionVectors.outpoint)
                ),
            ]
        )
        let selected = [
            Tokens.SelectedInput(output: listed.outputs[0], amount: 80),
        ]
        let resolved = try await Tokens.resolveInputBEEF(
            listed: listed,
            selected: selected,
            listings: nil
        )
        XCTAssertEqual(
            try resolved.serialized(limits: WalletBEEFLimits.standard),
            try beef.serialized(limits: WalletBEEFLimits.standard)
        )
    }

    func test_tokenSendRefusesInputsWithoutCustomInstructions() throws {
        let identity = try ActionVectors.identity()
        let first = try WalletOutput(
            satoshis: 1,
            spendable: true,
            customInstructions: nil,
            tags: ["bsv21:\(ActionVectors.tokenID)", "amt:80", "id:tok_0"],
            outpoint: try Outpoint(ActionVectors.outpoint)
        )
        XCTAssertThrowsError(
            try Tokens.buildSend(
                identity: identity,
                tokenId: ActionVectors.tokenID,
                recipients: [
                    Tokens.Recipient(amount: 80, destination: .address(ActionVectors.payAddress)),
                ],
                selected: [Tokens.SelectedInput(output: first, amount: 80)],
                totalIn: 80,
                details: Bsv21TokenDetails(
                    isActive: true,
                    feeAddress: ActionVectors.templateAddress,
                    feePerOutput: 1_000,
                    decimals: 0,
                    symbol: "GOLD"
                ),
                changeKeyID: "change-1"
            )
        ) { error in
            XCTAssertEqual(error as? OneSatActionError, .missingCustomInstructions)
        }
    }

    func test_purchaseBuilderRequiresOrdLockAndPaysTheSeller() throws {
        let identity = try ActionVectors.identity()
        let ctx = try dummyContext(identity: identity)
        let cancel = try Ordinals.cancelAddress(identity: identity, outpoint: ActionVectors.outpoint)
        let listing = try OrdLock.lock(
            cancelAddress: cancel.description,
            payAddress: ActionVectors.payAddress,
            price: 50_000
        )
        let prepared = try Ordinals.buildPurchase(
            ctx,
            outpoint: try Outpoint(ActionVectors.outpoint),
            listingScript: listing,
            listingSatoshis: 1,
            marketplaceAddress: ActionVectors.templateAddress,
            marketplaceRate: 0.02
        )
        XCTAssertEqual(prepared.outputs.count, 3)
        XCTAssertEqual(prepared.outputs[0].satoshis, 1)
        XCTAssertEqual(prepared.outputs[1].satoshis, 50_000)
        XCTAssertEqual(prepared.outputs[2].satoshis, 1_000)
        XCTAssertEqual(prepared.outputs[0].basket, OneSatConstants.ordinalsBasket)
    }

    private func walletOutput(
        tags: [String],
        instructions: String
    ) throws -> WalletOutput {
        try WalletOutput(
            satoshis: 1,
            spendable: true,
            customInstructions: instructions,
            tags: tags,
            outpoint: try Outpoint(ActionVectors.outpoint)
        )
    }

    private func dummyContext(identity: PrivateKey) throws -> OneSatContext {
        OneSatContext(
            identity: identity,
            storage: StorageClient(
                endpoint: URL(string: "https://example.invalid")!,
                transport: RejectTransport()
            ),
            auth: AuthID(identityKey: Hex.encode(identity.publicKey.compressedBytes))
        )
    }
}

private struct RejectTransport: AuthenticatedTransport {
    func send(
        method: String,
        path: String,
        query: String?,
        headers: [String: String],
        body: [UInt8]?
    ) async throws -> AuthenticatedResponse {
        throw AuthTransportError.notImplemented("offline")
    }
}
