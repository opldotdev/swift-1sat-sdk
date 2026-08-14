import XCTest
@testable import OneSatTemplates

final class BSV20Tests: XCTestCase {
    func test_transferMatchesTheTypeScriptEnvelope() throws {
        let token = try BSV20.transfer(tick: "SHUA", amount: "1000")
        XCTAssertEqual(
            try token.lock().hex,
            "0063036f726451126170706c69636174696f6e2f6273762d323000397b2270223a226273762d3230222c226f70223a227472616e73666572222c227469636b223a2253485541222c22616d74223a2231303030227d68"
        )
    }

    func test_decodeReadsATransfer() throws {
        let locked = try BSV20.transfer(tick: "SHUA", amount: "1000").lock()
        let decoded = try XCTUnwrap(BSV20.decode(locked))
        XCTAssertEqual(decoded.tokenData.operation, .transfer)
        XCTAssertEqual(decoded.tokenData.tick, "SHUA")
        XCTAssertEqual(decoded.tokenData.amount, "1000")
    }

    func test_decodeRefusesABSV21Transfer() throws {
        let tokenID = String(repeating: "aa", count: 32) + "_0"
        let locked = try BSV21.transfer(tokenID: tokenID, amount: "500").lock()
        XCTAssertNil(BSV20.decode(locked))
    }

    func test_anEmptyTickIsRefused() {
        XCTAssertThrowsError(try BSV20.transfer(tick: "", amount: "1"))
    }

    func test_aZeroAmountIsRefused() {
        XCTAssertThrowsError(try BSV20.transfer(tick: "SHUA", amount: "0"))
    }
}
