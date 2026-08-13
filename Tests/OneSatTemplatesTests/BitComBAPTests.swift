import BSVScript
import XCTest
@testable import OneSatTemplates

final class BitComBAPTests: XCTestCase {
    private let bapPrefix = BAPTemplate.protocolPrefix
    private let profileJSON = "{\"name\":\"Alice\"}"

    func test_lockDecodeRoundTripsProtocols() throws {
        var body = try TemplateScript.empty()
        try TemplateScript.appendPush(Array("ID".utf8), to: &body)
        try TemplateScript.appendPush(Array("id-key".utf8), to: &body)
        try TemplateScript.appendPush(Array("1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2".utf8), to: &body)
        let locked = try BitCom.lock(
            protocols: [BitComProtocolEntry(protocol: bapPrefix, script: body.bytes)]
        )
        let decoded = try XCTUnwrap(BitCom.decode(locked))
        XCTAssertEqual(decoded.scriptPrefix, [])
        XCTAssertEqual(decoded.protocols.count, 1)
        XCTAssertEqual(decoded.protocols[0].protocol, bapPrefix)
        XCTAssertEqual(decoded.protocols[0].script, body.bytes)
    }

    func test_aliasScriptDecodesTypeIdKeyAndRawProfile() throws {
        let script = try opReturnScript(fields: ["ALIAS", "bap-id-1", profileJSON])
        let bitcom = try XCTUnwrap(BitCom.decode(script))
        let bap = try XCTUnwrap(BAPTemplate.decode(bitcom))
        XCTAssertEqual(bap.type, .alias)
        XCTAssertEqual(bap.idKey, "bap-id-1")
        XCTAssertEqual(bap.profileJSON, profileJSON)
    }

    func test_idScriptDecodesIdKeyAndAddress() throws {
        let address = "1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2"
        let script = try opReturnScript(fields: ["ID", "bap-id-2", address])
        let bitcom = try XCTUnwrap(BitCom.decode(script))
        let bap = try XCTUnwrap(BAPTemplate.decode(bitcom))
        XCTAssertEqual(bap.type, .id)
        XCTAssertEqual(bap.idKey, "bap-id-2")
        XCTAssertEqual(bap.address, address)
        XCTAssertNil(bap.profileJSON)
    }

    func test_scriptWithoutOpReturnDecodesNil() throws {
        var script = try TemplateScript.empty()
        try TemplateScript.append(.dup, to: &script)
        XCTAssertNil(BitCom.decode(script))
    }

    private func opReturnScript(fields: [String]) throws -> Script {
        var script = try TemplateScript.empty()
        try TemplateScript.append(.zero, to: &script)
        try TemplateScript.append(.return, to: &script)
        try TemplateScript.appendPush(Array(bapPrefix.utf8), to: &script)
        for field in fields {
            try TemplateScript.appendPush(Array(field.utf8), to: &script)
        }
        return script
    }
}
