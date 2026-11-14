import Foundation
import XCTest
@testable import OneSatColor

/// `ColorOperations` against `Fixtures/onecolor-operations.json`: `authorityOperation`,
/// `requiredOperations` and `supplyChange` of `@bopen-io/color-permission-module` 0.2.3, run by Bun.
final class ColorOperationsTests: XCTestCase {
    func test_authorityOperationMatchesTheModule() throws {
        let rows = try XCTUnwrap(try colorFixture("onecolor-operations")["authorityOperation"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 16)
        for row in rows {
            let inputs = try XCTUnwrap(row["inputs"] as? Int), outputs = try XCTUnwrap(row["outputs"] as? Int)
            XCTAssertEqual(
                ColorOperations.authorityOperation(inputs: inputs, outputs: outputs).rawValue,
                row["operation"] as? String, "\(inputs) in, \(outputs) out"
            )
        }
    }

    func test_requiredOperationsAndSupplyChangeMatchTheModule() throws {
        let rows = try XCTUnwrap(try colorFixture("onecolor-operations")["requiredOperations"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 81)
        func holding(_ value: Any?) throws -> ColorHolding {
            let side = try XCTUnwrap(value as? [String: Any])
            return ColorHolding(
                value: try XCTUnwrap(UInt64(try XCTUnwrap(side["value"] as? String))),
                authority: try XCTUnwrap(side["authority"] as? Int)
            )
        }
        for row in rows {
            let inputs = try holding(row["inputs"]), outputs = try holding(row["outputs"])
            let label = "\(inputs) -> \(outputs)"
            let change = ColorOperations.supplyChange(inputs: inputs, outputs: outputs)
            let expected = try XCTUnwrap(row["supplyChange"] as? [String: String])
            XCTAssertEqual(String(change.transferred), expected["transferred"], label)
            XCTAssertEqual(String(change.burned), expected["burned"], label)
            XCTAssertEqual(String(change.minted), expected["minted"], label)
            do {
                let operations = try ColorOperations.required(inputs: inputs, outputs: outputs)
                XCTAssertEqual(operations.map(\.rawValue), row["operations"] as? [String], label)
            } catch {
                XCTAssertEqual(error.localizedDescription, row["error"] as? String, label)
            }
        }
    }

    func test_authorityInputsForADeclaredOperation() {
        XCTAssertEqual(ColorOperations.authorityInputs(for: .authorityTransfer, outputs: 1), 1)
        XCTAssertEqual(ColorOperations.authorityInputs(for: .authorityTransfer, outputs: 2), 2)
        XCTAssertEqual(ColorOperations.authorityInputs(for: .authorityCombine, outputs: 1), 2)
        XCTAssertEqual(ColorOperations.authorityInputs(for: .authoritySplit, outputs: 3), 1)
        XCTAssertEqual(ColorOperations.authorityInputs(for: .authorityEnd, outputs: 0), 1)
    }

    func test_assertOperationsComparesTheDeclaredSet() throws {
        let asset = try ColorAssetID(String(repeating: "ab", count: 32) + "_0")
        let plan = ColorPlan(assets: [.asset(asset)], operations: [
            .init(asset: .asset(asset), operation: .authorityTransfer), .init(asset: .asset(asset), operation: .mint),
        ])
        XCTAssertNoThrow(try ColorOperations.assertOperations(plan, assetID: asset, required: [.mint, .authorityTransfer]))
        XCTAssertThrowsError(try ColorOperations.assertOperations(plan, assetID: asset, required: [.mint, .authorityEnd])) {
            XCTAssertEqual(
                $0.localizedDescription,
                "BRC-207: \(asset) requires the operations [mint, authority-end] but the plan declares [authority-transfer, mint]"
            )
        }
    }
}
