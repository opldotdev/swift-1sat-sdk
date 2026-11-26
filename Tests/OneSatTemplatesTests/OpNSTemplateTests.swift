import Foundation
import XCTest
import BSVCore
import BSVScript
@testable import OneSatTemplates

/// `OpNSTemplate` against `OpNS.lock`, `decode` and `buildInscription` from `@1sat/templates`
/// (`Fixtures/opns-template.json`, generated with Bun; `{contract}` stands for `OPNS_CONTRACT`).
final class OpNSTemplateTests: XCTestCase {
    struct Decoded: Decodable, Equatable {
        let claimed: String
        let domain: String
        let pow: String
    }

    struct RoundTrip: Decodable {
        let claimed: String
        let domain: String
        let pow: String
        let script: String
        let decoded: Decoded?
    }

    struct Case: Decodable {
        let script: String
        let decoded: Decoded?
    }

    struct Inscription: Decodable {
        let domain: String
        let owner: String
        let script: String
    }

    struct Fixture: Decodable {
        let contract: String
        let genesis: String
        let difficulty: Int
        let contractLength: Int
        let roundTrip: [RoundTrip]
        let decodeNull: [String: Case]
        let decodeOther: [String: Case]
        let inscription: Inscription
    }

    private static func fixture() throws -> Fixture {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "Fixtures/opns-template", withExtension: "json")
                ?? Bundle.module.url(forResource: "opns-template", withExtension: "json", subdirectory: "Fixtures")
        )
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private func bytes(_ hex: String) throws -> [UInt8] {
        let expanded = hex.replacingOccurrences(of: "{contract}", with: Hex.encode(OpNSTemplate.contract))
        return try Hex.decode(expanded, maximumDecodedByteCount: 1_000_000)
    }

    private func script(_ hex: String) throws -> Script {
        try Script(bytes: try bytes(hex), maximumByteCount: 1_000_000)
    }

    private func shown(_ data: OpNSData?) -> Decoded? {
        data.map { Decoded(claimed: Hex.encode($0.claimed), domain: $0.domain, pow: Hex.encode($0.pow)) }
    }

    func test_constantsMatchTypes() throws {
        let fixture = try Self.fixture()
        XCTAssertEqual(Hex.encode(OpNSTemplate.contract), fixture.contract)
        XCTAssertEqual(OpNSTemplate.contract.count, fixture.contractLength)
        XCTAssertEqual(Hex.encode(OpNSTemplate.genesis), fixture.genesis)
        XCTAssertEqual(OpNSTemplate.difficulty, fixture.difficulty)
    }

    func test_lockMatchesTSAndDecodesBack() throws {
        let fixture = try Self.fixture()
        XCTAssertEqual(fixture.roundTrip.count, 4)
        for vector in fixture.roundTrip {
            let locked = try OpNSTemplate.lock(
                claimed: try bytes(vector.claimed),
                domain: vector.domain,
                pow: try bytes(vector.pow)
            )
            XCTAssertEqual(locked.bytes, try bytes(vector.script), vector.domain)
            let decoded = try XCTUnwrap(shown(OpNSTemplate.decode(locked)), vector.domain)
            XCTAssertEqual(decoded, vector.decoded, vector.domain)
            XCTAssertEqual(decoded, Decoded(claimed: vector.claimed, domain: vector.domain, pow: vector.pow))
        }
    }

    /// Not a node: P2PKH, a changed genesis byte, a script cut inside the covenant or the
    /// genesis push, an empty script, and the covenant with no state.
    func test_nonNodesDecodeToNil() throws {
        let fixture = try Self.fixture()
        XCTAssertEqual(
            Set(fixture.decodeNull.keys),
            ["p2pkh", "wrongGenesis", "truncatedContract", "truncatedGenesis", "empty", "contractOnly"]
        )
        for (name, vector) in fixture.decodeNull {
            XCTAssertNil(vector.decoded, name)
            XCTAssertNil(OpNSTemplate.decode(try script(vector.script)), name)
        }
    }

    /// TS reads the state leniently: a push cut short inside `pow` keeps what remains, the two
    /// bytes after the covenant are not checked, and `TextDecoder` drops a leading BOM.
    func test_lenientStateReadsAsTSDoes() throws {
        let fixture = try Self.fixture()
        XCTAssertEqual(Set(fixture.decodeOther.keys), ["truncatedPow", "otherSeparator", "bomDomain"])
        for (name, vector) in fixture.decodeOther {
            let expected = try XCTUnwrap(vector.decoded, name)
            XCTAssertEqual(shown(OpNSTemplate.decode(try script(vector.script))), expected, name)
        }
    }

    func test_buildInscriptionMatchesTS() throws {
        let vector = try Self.fixture().inscription
        let built = try OpNSTemplate.buildInscription(domain: vector.domain, ownerScript: try script(vector.owner))
        XCTAssertEqual(built.hex, vector.script)
        XCTAssertNil(OpNSTemplate.decode(built))
    }
}
