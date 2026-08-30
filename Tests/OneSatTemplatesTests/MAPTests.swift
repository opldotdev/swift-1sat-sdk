import XCTest
@testable import OneSatTemplates

final class MAPTests: XCTestCase {
    func test_setRoundTripsKeyValuePairs() throws {
        let script = try MAPTemplate.set([("app", "testapp"), ("type", "post")])
        let decoded = try XCTUnwrap(MAPTemplate.decode(script))
        XCTAssertEqual(decoded.command, MAPCommand.set.rawValue)
        XCTAssertEqual(decoded.data.map(\.0), ["app", "type"])
        XCTAssertEqual(decoded.data.map(\.1), ["testapp", "post"])
    }

    func test_addWritesKeyThenOnePushPerValue() throws {
        let script = try MAPTemplate.add(key: "tags", values: ["bitcoin", "ordinals"])
        let decoded = try XCTUnwrap(MAPTemplate.decode(script))
        XCTAssertEqual(decoded.command, MAPCommand.add.rawValue)
        XCTAssertEqual(decoded.adds, ["bitcoin", "ordinals"])
        XCTAssertEqual(decoded.data.first?.0, "tags")
        XCTAssertEqual(decoded.data.first?.1, "bitcoin ordinals")
        XCTAssertNotNil(BitCom.decode(script))
    }

    func test_removeNamesKeysOnly() throws {
        let script = try MAPTemplate.remove(keys: ["app", "type"])
        let decoded = try XCTUnwrap(MAPTemplate.decode(script))
        XCTAssertEqual(decoded.command, MAPCommand.remove.rawValue)
        XCTAssertEqual(decoded.data.map(\.0), ["app", "type"])
        XCTAssertEqual(decoded.data.map(\.1), ["", ""])
    }

    func test_deleteNamesKeyThenValues() throws {
        let script = try MAPTemplate.delete(key: "tags", values: ["old"])
        let decoded = try XCTUnwrap(MAPTemplate.decode(script))
        XCTAssertEqual(decoded.command, MAPCommand.delete.rawValue)
        XCTAssertEqual(decoded.deletes, ["old"])
        XCTAssertEqual(decoded.data.first?.0, "tags")
    }

    func test_appSetsAppAndType() throws {
        let decoded = try XCTUnwrap(
            MAPTemplate.decode(try MAPTemplate.app("testapp", type: "post", additional: [("context", "tx")]))
        )
        XCTAssertEqual(decoded.command, MAPCommand.set.rawValue)
        XCTAssertEqual(decoded.data.map(\.0), ["app", "type", "context"])
        XCTAssertEqual(decoded.data.map(\.1), ["testapp", "post", "tx"])
    }
}
