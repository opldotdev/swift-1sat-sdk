import Foundation

/// One asset's token units and authority outputs on one side of a transaction (TS `Holding`,
/// without `jsonValue`: this wallet builds no BRC-161 JSON outputs).
public struct ColorHolding: Equatable, Sendable {
    public var value: UInt64
    public var authority: Int

    public init(value: UInt64 = 0, authority: Int = 0) {
        self.value = value
        self.authority = authority
    }
}

/// The BRC-207 operation rules of `@bopen-io/color-permission-module` 0.2.3
/// (`ColorPermissionModule.ts`): which operations a transaction performs on one existing asset.
public enum ColorOperations {
    /// TS `authorityOperation`: the authority operation for an asset's authority input and output counts.
    public static func authorityOperation(inputs: Int, outputs: Int) -> ColorPlan.Operation {
        if outputs == 0 { return .authorityEnd }
        if outputs < inputs { return .authorityCombine }
        return outputs == inputs ? .authorityTransfer : .authoritySplit
    }

    /// TS `authorityInputsFor`: the authority inputs to select for a declared authority operation.
    static func authorityInputs(for operation: ColorPlan.Operation, outputs: Int) -> Int {
        switch operation {
        case .authorityTransfer: outputs
        case .authorityCombine: outputs + 1
        default: 1
        }
    }

    /// TS `supplyChange`: value inputs fund value outputs first; the rest is burned or minted.
    public static func supplyChange(
        inputs: ColorHolding, outputs: ColorHolding
    ) -> (transferred: UInt64, burned: UInt64, minted: UInt64) {
        let transferred = min(inputs.value, outputs.value)
        return (transferred, inputs.value - transferred, outputs.value - transferred)
    }

    /// TS `requiredOperations`: the operations the asset's inputs and outputs require, in the
    /// module's order (transfer, burn, mint, then the authority operation).
    public static func required(inputs: ColorHolding, outputs: ColorHolding) throws -> [ColorPlan.Operation] {
        if inputs.authority == 0 && outputs.authority > 0 {
            throw ColorError.custody("an authority output needs an authority input of the same asset")
        }
        let change = supplyChange(inputs: inputs, outputs: outputs)
        if change.minted > 0 && inputs.authority == 0 {
            throw ColorError.custody("token outputs exceed the authenticated input balance")
        }
        var operations: [ColorPlan.Operation] = []
        if change.transferred > 0 { operations.append(.transfer) }
        if change.burned > 0 { operations.append(.burn) }
        if change.minted > 0 { operations.append(.mint) }
        if inputs.authority > 0 {
            operations.append(authorityOperation(inputs: inputs.authority, outputs: outputs.authority))
        }
        return operations
    }

    /// TS `assertOperations`: the plan must declare exactly the required operations for the asset
    /// (order is not compared).
    static func assertOperations(_ plan: ColorPlan, assetID: ColorAssetID, required: [ColorPlan.Operation]) throws {
        var declared: [ColorPlan.Operation] = []
        for entry in plan.operations where entry.asset == .asset(assetID) && !declared.contains(entry.operation) {
            declared.append(entry.operation)
        }
        guard declared.count == required.count, required.allSatisfy(declared.contains) else {
            let need = required.map(\.rawValue).joined(separator: ", ")
            let have = declared.map(\.rawValue).joined(separator: ", ")
            throw ColorError.custody("\(assetID) requires the operations [\(need)] but the plan declares [\(have)]")
        }
    }
}
