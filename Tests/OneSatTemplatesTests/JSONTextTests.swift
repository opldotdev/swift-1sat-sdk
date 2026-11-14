import Foundation
import XCTest
@testable import OneSatTemplates

/// `JSONText.quote` and the BSV-20/BSV-21 inscription JSON against `JSON.stringify`
/// (`Fixtures/json-stringify.json`, generated with Bun from `@1sat/templates`).
final class JSONTextTests: XCTestCase {
    private static func fixture() throws -> [String: Any] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "Fixtures/json-stringify", withExtension: "json")
                ?? Bundle.module.url(forResource: "json-stringify", withExtension: "json", subdirectory: "Fixtures")
        )
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    /// The string the fixture's UTF-16 code units spell, or nil when they hold a lone surrogate,
    /// which a Swift `String` cannot represent.
    static func string(_ units: Any?) throws -> String? {
        let codeUnits = try XCTUnwrap(units as? [Int]).map { UInt16($0) }
        var scalars = String.UnicodeScalarView()
        var iterator = codeUnits.makeIterator()
        var decoder = UTF16()
        while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar): scalars.append(scalar)
            case .emptyInput: return String(scalars)
            case .error: return nil
            }
        }
    }

    func test_quoteMatchesJSONStringify() throws {
        let cases = try XCTUnwrap(try Self.fixture()["strings"] as? [[String: Any]])
        XCTAssertGreaterThan(cases.count, 40)
        var loneSurrogates = 0
        for row in cases {
            let expected = try XCTUnwrap(row["json"] as? String)
            guard let text = try Self.string(row["utf16"]) else {
                // JSON.stringify writes these as `\udxxx`; Swift strings cannot carry them.
                XCTAssertTrue(expected.contains("\\ud"), expected)
                loneSurrogates += 1
                continue
            }
            XCTAssertEqual(JSONText.quote(text), expected, "\(Array(text.unicodeScalars.map(\.value)))")
        }
        XCTAssertEqual(loneSurrogates, 3)
    }

    func test_bsv21DeployJSONEscapesControlCharactersAsTSDoes() throws {
        let bsv21 = try XCTUnwrap(try Self.fixture()["bsv21"] as? [String: Any])
        let symbol = try XCTUnwrap(try Self.string(bsv21["symbol"]))
        let icon = try XCTUnwrap(try Self.string(bsv21["icon"]))
        let decimals = try XCTUnwrap(bsv21["decimals"] as? Int)
        XCTAssertEqual(
            try BSV21.deployMint(
                symbol: symbol, amount: try XCTUnwrap(bsv21["amount"] as? String), decimals: decimals, icon: icon
            ).lock().hex,
            try XCTUnwrap(bsv21["deployMint"] as? String)
        )
        XCTAssertEqual(
            try BSV21.deployAuth(symbol: symbol, decimals: 2, icon: icon).lock().hex,
            try XCTUnwrap(bsv21["deployAuth"] as? String)
        )
        // The escaped deploy reads back to the same fields.
        let decoded = try XCTUnwrap(BSV21.decode(try BSV21.deployMint(
            symbol: symbol, amount: "1", icon: icon
        ).lock()))
        XCTAssertEqual(decoded.tokenData.symbol, symbol)
        XCTAssertEqual(decoded.tokenData.icon, icon)
    }

    func test_bsv20TransferJSONEscapesControlCharactersAsTSDoes() throws {
        let bsv20 = try XCTUnwrap(try Self.fixture()["bsv20"] as? [String: Any])
        let tick = try XCTUnwrap(try Self.string(bsv20["tick"]))
        XCTAssertEqual(
            try BSV20.transfer(tick: tick, amount: try XCTUnwrap(bsv20["amount"] as? String)).lock().hex,
            try XCTUnwrap(bsv20["transfer"] as? String)
        )
    }
}
