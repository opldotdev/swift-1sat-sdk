import BSVCore
import BSVInterpreter
import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet
import OneSatTemplates
import ToolboxActions
import XCTest
@testable import OneSatActions

/// `utils/signOrdinalInput.ts` and the OpNS publish lock. Hex is `@bsv/sdk` 4.0.1 +
/// `@ipld/dag-cbor` 10.0.2 running the `registerOpns` + `applyOpnsRegister` steps (and the
/// `signPushDropInput` sighash) with `ActionVectors.identity()` and name outpoint
/// `ActionVectors.outpoint`.
final class SignOrdinalInputTests: XCTestCase {
    private let limits = WalletTransactionLimits.standard

    /// Profile `{ domain: '1sat.name' }`.
    static let lockDomainOnly =
        "21021eef6b76cbae63c88d6d3889a394088f822d94a993f98ff033e4e7ba1b1f294cac086964656e746974792102bd1e9f9470dad82f75c4ffd03ffe9a5ddc2c5a718084727c027b17e9b7cfd8a50770726f66696c6512a166646f6d61696e69317361742e6e616d6546304402202ef31c20a914a6a53db56ce287ea2106fec2cbea987a6b5f46b8c4d0addb92bc02206b3f6884bf2017de50f04733092cd74688d82261926f81d577dc21b91e6306426d6d75"
    /// Profile `{ domain: '1sat.name', name: 'Alice', avatar: ef…ef_1 }`.
    static let lockFull =
        "21021eef6b76cbae63c88d6d3889a394088f822d94a993f98ff033e4e7ba1b1f294cac086964656e746974792102bd1e9f9470dad82f75c4ffd03ffe9a5ddc2c5a718084727c027b17e9b7cfd8a50770726f66696c654aa3646e616d6565416c696365666176617461725824efefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefef0100000066646f6d61696e69317361742e6e616d654630440220425cd552ebd1a8523aba59e44a6ef8569d5a2b2d0757a356c3e8c601122cc30902206f486d7be2e57ee854ee94e92f1bf52e9bae2edbdf3e7a6d65d953213bbe04016d6d75"
    /// `lockDomainOnly` + inscription envelope (`ordfs/dir`, `hello`).
    static let lockInscribed = lockDomainOnly
        + "0063036f726451096f726466732f646972000568656c6c6f68"
    /// PushDrop unlock of `lockDomainOnly` spent to one 1-sat P2PKH output.
    static let unlockDomainOnly =
        "483045022100acfa045ecd9aa48529a7b17c52ded89d41b04be29bf050c69d67d8f4207cdea80220047f81ac26ad848ff438a3388dc47575843ed42d30fed21313cd48c3fafff0d141"
    /// The same spend of `lockInscribed`.
    static let unlockInscribed =
        "4830450221008166ba92a7183f49733372db9607fb1f37e7e2b46160005129e30f848755a4940220523cf9836c09dc2607802f47b1503580fa7c49b5e746ec4ad5598ba45f57814b41"

    /// Outpoint the golden spends consume (TS `sourceTXID: '00'.repeat(32)`, vout 0).
    private static let spentOutpoint = String(repeating: "00", count: 32) + ".0"

    private static var registerKeyID: String {
        "opns:" + String(repeating: "aa", count: 32) + "_0"
    }

    func test_publishLockMatchesTheTypeScriptSealedLock() async throws {
        let identity = try ActionVectors.identity()
        let outpoint = try Outpoint(ActionVectors.outpoint)
        XCTAssertEqual(OpNS.registerKeyID(outpoint), Self.registerKeyID)
        let domainOnly = try await OpNS.publishLock(
            identity: identity,
            nameOutpoint: outpoint,
            profile: OpnsFields.Profile(domain: "1sat.name")
        )
        XCTAssertEqual(domainOnly.hex, Self.lockDomainOnly)
        let full = try await OpNS.publishLock(
            identity: identity,
            nameOutpoint: outpoint,
            profile: OpnsFields.Profile(
                domain: "1sat.name",
                name: "Alice",
                avatar: try OpnsFields.outpointWire(String(repeating: "ef", count: 32) + "_1")
            )
        )
        XCTAssertEqual(full.hex, Self.lockFull)
    }

    func test_publishedRecordReadsFieldsAndSignatureVerifies() async throws {
        let identity = try ActionVectors.identity()
        for hex in [Self.lockFull, Self.lockInscribed] {
            let record = try XCTUnwrap(OpNS.publishedRecord(from: try script(hex)))
            XCTAssertEqual(record.identityKey, identity.publicKey)
            let lockKey = try P1SATKey.publicKey(
                identity: identity,
                keyID: Self.registerKeyID,
                counterparty: .anyone,
                forSelf: true
            )
            XCTAssertEqual(record.lockKey, lockKey)
            XCTAssertEqual(record.profile?.domain, "1sat.name")

            // `verifySignature` as an `anyone` wallet with the publisher's identity, as TS does.
            let fields = try XCTUnwrap(SignOrdinalInput.pushDrop(in: try script(hex))).fields.dropLast()
            let verified = try await ProtoWallet.anyone().verifySignature(.init(
                protocolID: try OneSatConstants.p1satProtocolID,
                keyID: WalletKeyID(Self.registerKeyID),
                counterparty: .publicKey(identity.publicKey),
                payload: .data(fields.flatMap { $0 }),
                signature: try ECDSASignature(derBytes: record.signature)
            ))
            XCTAssertTrue(verified.valid)
        }
        XCTAssertEqual(
            OpNS.publishedRecord(from: try script(Self.lockFull))?.profile?.name,
            "Alice"
        )
    }

    func test_publishedRecordRefusesAPositionalLockAndPlainScripts() async throws {
        let identity = try ActionVectors.identity()
        let positional = try await PushDrop.lockingScript(
            fields: [identity.publicKey.compressedBytes, [UInt8](repeating: 0, count: 72)],
            using: ProtoWallet(rootKey: identity),
            protocolID: try OneSatConstants.p1satProtocolID,
            keyID: WalletKeyID(Self.registerKeyID),
            counterparty: .anyone,
            forSelf: true,
            lockPosition: .beforeCompatibility
        )
        XCTAssertNotNil(SignOrdinalInput.pushDrop(in: positional))
        XCTAssertNil(OpNS.publishedRecord(from: positional))
        let p2pkh = try ActionScript.payToPublicKeyHash(ActionVectors.templateAddress)
        XCTAssertNil(SignOrdinalInput.pushDrop(in: p2pkh))
        XCTAssertNil(OpNS.publishedRecord(from: p2pkh))
        XCTAssertNil(SignOrdinalInput.pushDrop(in: try script(ActionVectors.inscribeP2PKHSuffix)))
    }

    func test_pushDropUnlockMatchesTypeScriptAndExecutes() throws {
        let identity = try ActionVectors.identity()
        for (lockHex, unlockHex) in [
            (Self.lockDomainOnly, Self.unlockDomainOnly),
            (Self.lockInscribed, Self.unlockInscribed),
        ] {
            let lock = try script(lockHex)
            let transaction = try spend(lock)
            let unlock = try SignOrdinalInput.unlockingScript(
                identity: identity,
                transaction: transaction,
                inputIndex: 0,
                customInstructions: OrdinalRemittance.buildCustomInstructions(
                    protocolID: try OneSatConstants.p1satProtocolID,
                    keyID: Self.registerKeyID,
                    counterparty: "anyone"
                )
            )
            XCTAssertEqual(unlock.hex, unlockHex)
            XCTAssertEqual(unlock.bytes.count, 73)
            XCTAssertEqual(unlock.bytes.last, 0x41)
            let result = try execute(unlock, lock: lock, transaction: transaction)
            XCTAssertEqual(result.stack.last, [1])

            // No counterparty in the CI takes the PushDrop default, `anyone`.
            let defaulted = try SignOrdinalInput.unlockingScript(
                identity: identity,
                transaction: transaction,
                inputIndex: 0,
                customInstructions: try CustomInstructions(keyID: Self.registerKeyID).encoded()
            )
            XCTAssertEqual(defaulted.hex, unlockHex)
        }
    }

    func test_ordinalTransferSignerUnlocksAPublishedName() throws {
        let identity = try ActionVectors.identity()
        let transaction = try spend(try script(Self.lockInscribed))
        let spends = try Ordinals.signP2PKHInputs(identity, transaction, [
            Ordinals.P2PKHSigner(
                outpoint: try Outpoint(Self.spentOutpoint),
                protocolID: try OneSatConstants.p1satProtocolID,
                keyID: Self.registerKeyID,
                counterparty: .anyone
            ),
        ])
        XCTAssertEqual(spends[0]?.hex, Self.unlockInscribed)
    }

    func test_plainSourceStillGetsTheP2PKHUnlock() throws {
        let identity = try ActionVectors.identity()
        let address = try P1SATKey.address(
            identity: identity,
            keyID: ActionVectors.outpoint,
            counterparty: .self,
            forSelf: true
        )
        let lock = try ActionScript.payToPublicKeyHash(address)
        let transaction = try spend(lock)
        let unlock = try SignOrdinalInput.unlockingScript(
            identity: identity,
            transaction: transaction,
            inputIndex: 0,
            customInstructions: try CustomInstructions(keyID: ActionVectors.outpoint).encoded()
        )
        let expected = try SignP2PKH.unlockingScript(
            identity: identity,
            transaction: transaction,
            inputIndex: 0,
            protocolID: try OneSatConstants.p1satProtocolID,
            keyID: ActionVectors.outpoint
        )
        XCTAssertEqual(unlock, expected)
        XCTAssertEqual(try execute(unlock, lock: lock, transaction: transaction).stack.last, [1])
    }

    func test_pushDropUnlockRefusesAKeyThatDoesNotMatchTheLock() throws {
        let other = try ActionVectors.recipient()
        let transaction = try spend(try script(Self.lockDomainOnly))
        XCTAssertThrowsError(try SignOrdinalInput.unlockingScript(
            identity: other,
            transaction: transaction,
            inputIndex: 0,
            protocolID: try OneSatConstants.p1satProtocolID,
            keyID: Self.registerKeyID,
            counterparty: .anyone
        )) { error in
            XCTAssertEqual(error as? PushDropError, .privateKeyDoesNotMatchPublicKey(inputIndex: 0))
        }
    }

    private func script(_ hex: String) throws -> Script {
        try Script(hex: hex, maximumByteCount: ActionScript.maximumByteCount)
    }

    /// One input (`spentOutpoint`, 1 sat, `lock`) to one 1-sat P2PKH output, version 1, lockTime 0.
    private func spend(_ lock: Script) throws -> Transaction {
        Transaction(
            version: 1,
            inputs: [
                TransactionInput(
                    previousOutput: try Outpoint(Self.spentOutpoint),
                    unlockingScript: try Script(bytes: [], maximumByteCount: 10),
                    sequence: 0xffff_ffff,
                    sourceOutput: TransactionOutput(satoshis: 1, lockingScript: lock)
                ),
            ],
            outputs: [
                TransactionOutput(
                    satoshis: 1,
                    lockingScript: try ActionScript.payToPublicKeyHash(ActionVectors.templateAddress)
                ),
            ],
            lockTime: 0
        )
    }

    private func execute(
        _ unlock: Script,
        lock: Script,
        transaction: Transaction
    ) throws -> ScriptExecutionResult {
        var transaction = transaction
        transaction.inputs[0].unlockingScript = unlock
        let source = TransactionOutput(satoshis: 1, lockingScript: lock)
        return try ScriptInterpreter.execute(
            unlockingScript: unlock,
            lockingScript: lock,
            configuration: ScriptExecutionConfiguration(
                era: .afterGenesis, flags: [.enableForkID, .derSignatures, .lowS, .nullFail],
                resourceLimits: .standard
            ),
            context: ScriptExecutionContext(
                transaction: transaction, inputIndex: 0, spentOutput: source,
                transactionLimits: limits
            )
        )
    }
}
