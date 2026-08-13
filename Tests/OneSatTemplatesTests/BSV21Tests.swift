import XCTest
@testable import OneSatTemplates

final class BSV21Tests: XCTestCase {
    private let tokenID = String(repeating: "aa", count: 32) + "_0"

    func test_deployMintMatchesTheTypeScriptEnvelope() throws {
        let token = try BSV21.deployMint(
            symbol: "GOLD",
            amount: "1000000",
            decimals: 8,
            icon: "https://example.com/icon.png"
        )
        XCTAssertEqual(
            try token.lock().hex,
            "0063036f726451126170706c69636174696f6e2f6273762d3230004c6e7b2270223a226273762d3230222c226f70223a226465706c6f792b6d696e74222c2273796d223a22474f4c44222c22616d74223a2231303030303030222c22646563223a2238222c2269636f6e223a2268747470733a2f2f6578616d706c652e636f6d2f69636f6e2e706e67227d68"
        )
    }

    func test_deployMintOmitsZeroDecimals() throws {
        let token = try BSV21.deployMint(symbol: "X", amount: "1")
        XCTAssertEqual(
            try token.lock().hex,
            "0063036f726451126170706c69636174696f6e2f6273762d323000357b2270223a226273762d3230222c226f70223a226465706c6f792b6d696e74222c2273796d223a2258222c22616d74223a2231227d68"
        )
    }

    func test_transferBurnAuthAndMintMatchTheTypeScriptEnvelopes() throws {
        XCTAssertEqual(
            try BSV21.transfer(tokenID: tokenID, amount: "500").lock().hex,
            "0063036f726451126170706c69636174696f6e2f6273762d3230004c747b2270223a226273762d3230222c226f70223a227472616e73666572222c226964223a22616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161615f30222c22616d74223a22353030227d68"
        )
        XCTAssertEqual(
            try BSV21.burn(tokenID: tokenID, amount: "1").lock().hex,
            "0063036f726451126170706c69636174696f6e2f6273762d3230004c6e7b2270223a226273762d3230222c226f70223a226275726e222c226964223a22616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161615f30222c22616d74223a2231227d68"
        )
        XCTAssertEqual(
            try BSV21.deployAuth(symbol: "MINT", decimals: 2).lock().hex,
            "0063036f726451126170706c69636174696f6e2f6273762d323000387b2270223a226273762d3230222c226f70223a226465706c6f792b61757468222c2273796d223a224d494e54222c22646563223a2232227d68"
        )
        XCTAssertEqual(
            try BSV21.auth(tokenID: tokenID).lock().hex,
            "0063036f726451126170706c69636174696f6e2f6273762d3230004c647b2270223a226273762d3230222c226f70223a2261757468222c226964223a22616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161615f30227d68"
        )
        XCTAssertEqual(
            try BSV21.mint(tokenID: tokenID, amount: "10").lock().hex,
            "0063036f726451126170706c69636174696f6e2f6273762d3230004c6f7b2270223a226273762d3230222c226f70223a226d696e74222c226964223a22616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161615f30222c22616d74223a223130227d68"
        )
    }

    func test_decodeReadsADeployMint() throws {
        let locked = try BSV21.deployMint(
            symbol: "GOLD",
            amount: "1000000",
            decimals: 8,
            icon: "https://example.com/icon.png"
        ).lock()
        let decoded = try XCTUnwrap(BSV21.decode(locked))
        XCTAssertEqual(decoded.tokenData.operation, .deployMint)
        XCTAssertEqual(decoded.tokenData.symbol, "GOLD")
        XCTAssertEqual(decoded.tokenData.amount, "1000000")
        XCTAssertEqual(decoded.tokenData.decimals, 8)
        XCTAssertEqual(decoded.tokenData.icon, "https://example.com/icon.png")
    }

    func test_anEmptySymbolIsRefused() {
        XCTAssertThrowsError(try BSV21.deployMint(symbol: "", amount: "1"))
    }

    func test_aMalformedTokenIDIsRefused() {
        XCTAssertThrowsError(try BSV21.transfer(tokenID: "not-an-outpoint", amount: "1"))
    }
}
