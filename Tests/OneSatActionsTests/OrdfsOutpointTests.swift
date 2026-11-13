import BSVCore
import BSVTransaction
import XCTest
@testable import OneSatActions

/// Ports `packages/actions/test/ordfsOutpoint.test.ts`: both ORDFS formats store outpoints as
/// the 36-byte transaction-wire form (internal-order txid, little-endian vout).
final class OrdfsOutpointTests: XCTestCase {
    private static let txid = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    private func outpoint(_ vout: UInt32) throws -> Outpoint {
        Outpoint(transactionID: try TransactionID(displayHex: Self.txid), outputIndex: vout)
    }

    func test_encodesTxidInInternalOrderAndVoutLittleEndian() throws {
        let wire = try outpoint(3).wireBytes
        XCTAssertEqual(wire.count, 36)
        XCTAssertEqual(wire[0], 0xef)
        XCTAssertEqual(wire[31], 0x01)
        XCTAssertEqual(Array(wire[32..<36]), [3, 0, 0, 0])
        XCTAssertEqual(try Outpoint(wireBytes: wire), try outpoint(3))
        XCTAssertEqual(
            Array(try Outpoint(transactionID: TransactionID(displayHex: Self.txid), outputIndex: 0x0102_0304)
                .wireBytes[32..<36]),
            [0x04, 0x03, 0x02, 0x01]
        )
    }

    func test_dirRoundTripsANonPalindromicTxid() throws {
        let encoded = try OrdfsDir.encode(OrdfsDirManifest(entries: [
            OrdfsDirEntry(name: try OrdfsDir.name("f"), isDirectory: false, ref: .outpoint(try outpoint(1))),
        ]))
        XCTAssertEqual(encoded[6], 0xef)
        XCTAssertEqual(encoded[37], 0x01)
        XCTAssertEqual(try OrdfsDir.decode(encoded).entries[0].ref, .outpoint(try outpoint(1)))
    }

    func test_patchUsesTheSame36ByteLayout() throws {
        let bytes = try OrdfsPatch.encode(OrdfsPatchRecord(base: try outpoint(7), delta: Vcdiff.magic + [0x00]))
        XCTAssertEqual(bytes[1], 0xef)
        XCTAssertEqual(bytes[32], 0x01)
        XCTAssertEqual(try OrdfsPatch.decode(bytes).base, try outpoint(7))
    }
}
