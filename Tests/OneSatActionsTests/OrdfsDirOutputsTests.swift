import BSVCore
import BSVKeys
import BSVScript
import OneSatTemplates
import XCTest
@testable import OneSatActions

/// Ports `packages/actions/test/buildOrdFsDirOutputs.test.ts` and `dataScript.test.ts`.
final class OrdfsDirOutputsTests: XCTestCase {
    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    private func address() throws -> String {
        Address(publicKey: try ActionVectors.recipient().publicKey, network: .mainnet).description
    }

    // MARK: buildDataScript

    func test_dataScriptIsOpFalseOpReturnThenADecodableBSection() throws {
        let script = try OrdfsDirOutputs.dataScript(bytes("hello"), contentType: "text/plain")
        XCTAssertEqual(script.bytes[0], Opcode.zero.rawValue)
        XCTAssertEqual(script.bytes[1], Opcode.return.rawValue)
        let decoded = try XCTUnwrap(BTemplate.decode(script))
        XCTAssertEqual(decoded.mediaType, "text/plain")
        XCTAssertEqual(decoded.encoding, "binary")
        XCTAssertEqual(decoded.data, bytes("hello"))
    }

    func test_dataScriptMatchesTheTypeScriptBytes() throws {
        // OP_FALSE OP_RETURN <19HxigV4QyBv3tHpQVcUEQyq1pzZVdoAut> <"hello"> <"text/plain"> <"binary">
        let prefix: String = Hex.encode(Array(BTemplate.prefix.utf8))
        let expected: String = "006a22" + prefix + "0568656c6c6f0a746578742f706c61696e0662696e617279"
        let script = try OrdfsDirOutputs.dataScript(bytes("hello"), contentType: "text/plain")
        XCTAssertEqual(Hex.encode(script.bytes), expected)
    }

    // MARK: buildOrdFsDirOutputs

    func test_buildsFileSubdirAndRootOutputsOnlyTheRootIsManifest() throws {
        let result = try OrdfsDirOutputs.build(
            [
                OrdfsDirFile(path: "theme.json", content: bytes("{\"x\":1}"), contentType: "application/json"),
                OrdfsDirFile(path: "refs/a.md", content: bytes("hi"), contentType: "text/markdown"),
            ],
            locking: .address(try address()),
            map: [("app", "test"), ("type", "registry:file")]
        )
        XCTAssertEqual(result.outputs.count, 4)
        XCTAssertEqual(result.manifestVout, 3)
        XCTAssertEqual(result.outputs.map(\.isManifest), [false, false, false, true])
        XCTAssertEqual(result.outputs.map(\.satoshis), [0, 0, 0, 1])
        XCTAssertEqual(
            result.outputs.map(\.description),
            ["file: theme.json", "file: refs/a.md", "dir: refs/", "manifest (ord-fs/json)"]
        )
        for output in result.outputs {
            XCTAssertFalse(output.lockingScript.bytes.isEmpty)
        }

        // Mixed: B leaves, an ordinal root locked by P2PKH ahead of the envelope, MAP after it.
        XCTAssertEqual(try XCTUnwrap(BTemplate.decode(result.outputs[2].lockingScript)).data, bytes(#"{"a.md":"_1"}"#))
        let root = try XCTUnwrap(Inscription.decode(result.manifestScript))
        XCTAssertEqual(root.contentType, "ord-fs/json")
        XCTAssertEqual(root.content, bytes(#"{"theme.json":"_0","refs":"_2"}"#))
        XCTAssertEqual(
            Array(result.manifestScript.bytes.prefix(25)),
            try ActionScript.payToPublicKeyHash(try address()).bytes
        )
        // The content holds a 0x6a ("j"), which BitCom.decode would stop at, so compare the
        // MAP suffix bytes directly.
        let map = try MAPTemplate.set([("app", "test"), ("type", "registry:file")]).bytes
        XCTAssertEqual(Array(result.manifestScript.bytes.suffix(map.count)), map)
    }

    func test_writesEveryOutputAsOneSatoshiInInscriptionMode() throws {
        let result = try OrdfsDirOutputs.build(
            [OrdfsDirFile(path: "a.txt", content: bytes("hi"), contentType: "text/plain")],
            writeMode: .inscription,
            locking: .address(try address())
        )
        XCTAssertEqual(result.outputs.map(\.satoshis), [1, 1])
        let leaf = try XCTUnwrap(Inscription.decode(result.outputs[0].lockingScript))
        XCTAssertEqual(leaf.content, bytes("hi"))
        XCTAssertEqual(leaf.contentType, "text/plain")
    }

    func test_resolverLockingIsCalledPerVout() throws {
        let lock = try ActionScript.payToPublicKeyHash(try address())
        let result = try OrdfsDirOutputs.build(
            [
                OrdfsDirFile(path: "a/x", content: bytes("1"), contentType: "text/plain"),
                OrdfsDirFile(path: "y", content: bytes("2"), contentType: "text/plain"),
            ],
            writeMode: .inscription,
            locking: .resolve { vout in
                guard vout < 4 else { throw OrdfsDirTreeError("unexpected vout \(vout)") }
                return lock
            }
        )
        XCTAssertEqual(result.outputs.count, 4)
    }

    func test_isMAPAgnosticTheSuffixIsPresentOnlyWhenSupplied() throws {
        let file = OrdfsDirFile(path: "a.json", content: bytes("1"), contentType: "application/json")
        let withMap = try OrdfsDirOutputs.build([file], locking: .address(try address()), map: [("app", "x"), ("type", "y")])
        let without = try OrdfsDirOutputs.build([file], locking: .address(try address()))
        XCTAssertGreaterThan(withMap.manifestScript.bytes.count, without.manifestScript.bytes.count)
        XCTAssertNil(MAPTemplate.decode(without.manifestScript))
    }

    func test_bModeWritesEveryOutputAsZeroSatB() throws {
        let result = try OrdfsDirOutputs.build(
            [
                OrdfsDirFile(path: "a.json", content: bytes("{\"x\":1}"), contentType: "application/json"),
                OrdfsDirFile(path: "refs/a.md", content: bytes("hi"), contentType: "text/markdown"),
            ],
            writeMode: .b
        )
        XCTAssertEqual(result.outputs.count, 4)
        XCTAssertEqual(result.outputs.map(\.satoshis), [0, 0, 0, 0])
        for output in result.outputs {
            XCTAssertEqual(Array(output.lockingScript.bytes.prefix(2)), [0x00, 0x6a])
        }
    }

    func test_bModeComposesBAndMAPIntoOneOpReturn() throws {
        let result = try OrdfsDirOutputs.build(
            [OrdfsDirFile(path: "a.json", content: bytes("1"), contentType: "application/json")],
            writeMode: .b,
            map: [("app", "x"), ("type", "y")]
        )
        let script = result.outputs[result.manifestVout].lockingScript
        let decodedB = try XCTUnwrap(BTemplate.decode(script))
        XCTAssertEqual(decodedB.mediaType, "ord-fs/json")
        XCTAssertEqual(decodedB.data, result.tree.root.jsonBytes)
        let decodedMap = try XCTUnwrap(MAPTemplate.decode(script))
        XCTAssertEqual(decodedMap.data.map(\.0), ["app", "type"])
        XCTAssertEqual(decodedMap.data.map(\.1), ["x", "y"])
        XCTAssertEqual(try XCTUnwrap(BitCom.decode(script)).protocols.map(\.protocol), [BTemplate.prefix, MAPTemplate.prefix])
    }

    func test_bModeRequiresNoLocking() throws {
        let result = try OrdfsDirOutputs.build(
            [OrdfsDirFile(path: "a.txt", content: bytes("hi"), contentType: "text/plain")],
            writeMode: .b
        )
        XCTAssertEqual(result.outputs.count, 2)
    }

    func test_inscriptionAndMixedModesRequireLocking() {
        let file = OrdfsDirFile(path: "a.txt", content: bytes("hi"), contentType: "text/plain")
        for mode in [OrdfsDirWriteMode.inscription, .mixed] {
            XCTAssertThrowsError(try OrdfsDirOutputs.build([file], writeMode: mode)) { error in
                XCTAssertTrue((error as? OrdfsDirTreeError)?.message.contains("'locking' is required") == true)
            }
        }
    }

    func test_aipSignsTheRootAfterMAP() throws {
        let file = OrdfsDirFile(path: "a.txt", content: bytes("hi"), contentType: "text/plain")
        var signedInput: Script?
        let result = try OrdfsDirOutputs.build([file], writeMode: .b, map: [("app", "x")]) { script in
            signedInput = script
            return try AIPSign.apply(to: script, signingKey: try ActionVectors.identity())
        }
        XCTAssertNotNil(MAPTemplate.decode(try XCTUnwrap(signedInput)))
        XCTAssertGreaterThan(result.manifestScript.bytes.count, try XCTUnwrap(signedInput).bytes.count)
        XCTAssertEqual(result.outputs.last?.lockingScript, result.manifestScript)
    }
}
