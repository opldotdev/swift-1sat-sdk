import BSVScript
import BSVTransaction
import BSVWallet

/// Rotate plain BSV out of `1sat-deposit` into ordinary BRC-29 funding.
///
/// Matches `@1sat/actions` `sweep/sweepDeposit.ts`.
public enum SweepDeposit {
    public struct Result: Equatable, Sendable {
        public let txid: String?
        public let swept: Int

        public init(txid: String? = nil, swept: Int) {
            self.txid = txid
            self.swept = swept
        }
    }

    public static func execute(_ ctx: OneSatContext, limit: Int = 50) async throws -> Result {
        let listed = try await ctx.storage.listOutputs(
            ctx.auth,
            try WalletListOutputsRequest(
                basket: OneSatConstants.depositBasket,
                include: .entireTransactions,
                includeCustomInstructions: true,
                pagination: WalletPagination(limit: UInt32(limit))
            )
        )
        if listed.outputs.isEmpty {
            return Result(swept: 0)
        }

        let inputs: [(outpoint: Outpoint, keyID: String)] = listed.outputs.compactMap { output in
            guard let text = output.customInstructions,
                  let parsed = try? CustomInstructions.parse(text)
            else { return nil }
            return (output.outpoint, parsed.keyID)
        }
        if inputs.isEmpty {
            return Result(swept: 0)
        }

        let actionInputs = try inputs.map { input in
            try WalletCreateActionInput(
                outpoint: input.outpoint,
                inputDescription: "Deposit sweep",
                unlockingScriptLength: OneSatConstants.p2pkhUnlockingScriptLength
            )
        }
        let result = try await TrackedAction.execute(
            ctx,
            description: "Sweep deposit funds",
            inputBEEF: listed.beef,
            inputs: actionInputs,
            outputs: [],
            options: TrackedAction.Options(
                randomizeOutputs: false,
                acceptDelayedBroadcast: false
            )
        ) { transaction in
            var spends: [UInt32: Script] = [:]
            for (index, input) in inputs.enumerated() {
                spends[UInt32(index)] = try SignP2PKH.unlockingScript(
                    identity: ctx.identity,
                    transaction: transaction,
                    inputIndex: index,
                    protocolID: try OneSatConstants.p1satProtocolID,
                    keyID: input.keyID,
                    counterparty: .self
                )
            }
            return spends
        }
        if let error = result.error {
            throw SweepDepositFailure(message: error)
        }
        return Result(txid: result.txid, swept: inputs.count)
    }
}

struct SweepDepositFailure: Error, Equatable {
    let message: String
}
