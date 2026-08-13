import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet
import OneSatTemplates

/// Time-lock actions from `packages/actions/src/locks/index.ts`.
public enum Locks {
    public struct Request: Equatable, Sendable {
        public let satoshis: UInt64
        public let until: Int

        public init(satoshis: UInt64, until: Int) {
            self.satoshis = satoshis
            self.until = until
        }
    }

    public struct LockData: Equatable, Sendable {
        public var totalLocked: UInt64
        public var unlockable: UInt64
        public var nextUnlock: Int

        public init(totalLocked: UInt64 = 0, unlockable: UInt64 = 0, nextUnlock: Int = 0) {
            self.totalLocked = totalLocked
            self.unlockable = unlockable
            self.nextUnlock = nextUnlock
        }
    }

    public struct PreparedLock: Sendable {
        public let outputs: [WalletCreateActionOutput]
        public let description: String
    }

    public struct MaturedLock: Sendable {
        public let output: WalletOutput
        public let until: Int
        public let protocolID: WalletProtocolID
        public let keyID: String
    }

    public static func lockAddress(
        identity: PrivateKey,
        network: BitcoinNetwork = .mainnet
    ) throws -> Address {
        try P1SATKey.address(
            identity: identity,
            keyID: OneSatConstants.lockKeyID,
            counterparty: .self,
            forSelf: true,
            network: network
        )
    }

    public static func lockScript(address: String, until: Int) throws -> Script {
        try TimeLock.lock(address: address, until: until)
    }

    public static func buildLock(
        identity: PrivateKey,
        requests: [Request],
        network: BitcoinNetwork = .mainnet
    ) throws -> PreparedLock {
        guard !requests.isEmpty else { throw OneSatActionError.noLockRequests }
        let address = try lockAddress(identity: identity, network: network).description
        var outputs: [WalletCreateActionOutput] = []
        for request in requests {
            guard request.satoshis > 0 else { throw OneSatActionError.invalidSatoshis }
            guard request.until > 0 else { throw OneSatActionError.invalidBlockHeight }
            try outputs.append(
                WalletCreateActionOutput(
                    lockingScript: try lockScript(address: address, until: request.until).bytes,
                    satoshis: request.satoshis,
                    outputDescription: "Lock \(request.satoshis) sats until block \(request.until)",
                    basket: OneSatConstants.lockBasket,
                    customInstructions: try CustomInstructions(
                        protocolID: try OneSatConstants.p1satProtocolID,
                        keyID: OneSatConstants.lockKeyID
                    ).encoded(),
                    tags: ["until:\(request.until)"]
                )
            )
        }
        return PreparedLock(
            outputs: outputs,
            description: "Lock BSV in \(requests.count) output(s)"
        )
    }

    public static func lockBsv(
        _ ctx: OneSatContext,
        requests: [Request]
    ) async -> ActionResult {
        do {
            let prepared = try buildLock(
                identity: ctx.identity,
                requests: requests,
                network: ctx.chain.network
            )
            let result = try await TrackedAction.execute(
                ctx,
                description: prepared.description,
                outputs: prepared.outputs,
                options: TrackedAction.Options(acceptDelayedBroadcast: false)
            )
            if result.txid == nil, result.error == nil {
                return ActionResult.failure(.noTxidReturned, actionId: result.actionId)
            }
            return result
        } catch let error as OneSatActionError {
            return ActionResult.failure(error)
        } catch {
            return ActionResult.failure(error.localizedDescription)
        }
    }

    public static func maturedLocks(
        outputs: [WalletOutput],
        currentHeight: UInt32
    ) throws -> [MaturedLock] {
        var matured: [MaturedLock] = []
        for output in outputs {
            guard let untilTag = output.tags?.first(where: { $0.hasPrefix("until:") }),
                  let until = Int(untilTag.dropFirst(6))
            else { continue }
            guard until <= currentHeight else { continue }
            let protocolID: WalletProtocolID
            let keyID: String
            if let instructions = output.customInstructions {
                let parsed = try CustomInstructions.parse(instructions)
                protocolID = parsed.protocolID
                keyID = parsed.keyID
            } else {
                protocolID = try OneSatConstants.p1satProtocolID
                keyID = OneSatConstants.lockKeyID
            }
            matured.append(
                MaturedLock(
                    output: output,
                    until: until,
                    protocolID: protocolID,
                    keyID: keyID
                )
            )
        }
        if matured.isEmpty { throw OneSatActionError.noMaturedLocks }
        return matured
    }

    public static func buildUnlock(
        matured: [MaturedLock]
    ) throws -> (inputs: [WalletCreateActionInput], labels: [String], lockTime: UInt32) {
        guard !matured.isEmpty else { throw OneSatActionError.noMaturedLocks }
        let maxUntil = matured.map(\.until).max() ?? 0
        let inputs = try matured.map { lock in
            try WalletCreateActionInput(
                outpoint: lock.output.outpoint,
                inputDescription: "Locked BSV",
                unlockingScriptLength: OneSatConstants.timeLockUnlockingScriptLength,
                sequenceNumber: 0
            )
        }
        let labels = matured.compactMap { OneSatConstants.assetID(in: $0.output.tags) }.map {
            OneSatConstants.inputAssetLabel(basket: OneSatConstants.lockBasket, id: $0)
        }
        return (inputs, labels, UInt32(maxUntil))
    }

    public static func unlockBsv(_ ctx: OneSatContext) async -> ActionResult {
        do {
            guard let services = ctx.services else {
                return ActionResult.failure(.servicesRequired)
            }
            let height = try await services.currentHeight()
            let listed = try await ctx.storage.listOutputs(
                ctx.auth,
                try WalletListOutputsRequest(
                    basket: OneSatConstants.lockBasket,
                    include: .entireTransactions,
                    includeCustomInstructions: true,
                    includeTags: true,
                    pagination: WalletPagination(limit: 10_000)
                )
            )
            let matured = try maturedLocks(outputs: listed.outputs, currentHeight: height)
            let built = try buildUnlock(matured: matured)
            return try await TrackedAction.execute(
                ctx,
                description: "Unlock \(matured.count) lock(s)",
                inputs: built.inputs,
                outputs: [],
                labels: built.labels,
                lockTime: built.lockTime
            ) { transaction in
                var spends: [UInt32: Script] = [:]
                for (index, lock) in matured.enumerated() {
                    spends[UInt32(index)] = try UnlockScripts.timeLock(
                        identity: ctx.identity,
                        transaction: transaction,
                        inputIndex: index,
                        protocolID: lock.protocolID,
                        keyID: lock.keyID,
                        counterparty: .`self`
                    )
                }
                return spends
            }
        } catch let error as OneSatActionError {
            return ActionResult.failure(error)
        } catch {
            return ActionResult.failure(error.localizedDescription)
        }
    }

    public static func getLockData(
        outputs: [WalletOutput],
        currentHeight: UInt32
    ) -> LockData {
        var data = LockData()
        for output in outputs {
            guard let untilTag = output.tags?.first(where: { $0.hasPrefix("until:") }),
                  let until = Int(untilTag.dropFirst(6))
            else { continue }
            data.totalLocked += output.satoshis
            if until <= currentHeight {
                data.unlockable += output.satoshis
            } else if data.nextUnlock == 0 || until < data.nextUnlock {
                data.nextUnlock = until
            }
        }
        return data
    }

    public static func getLockData(_ ctx: OneSatContext) async throws -> LockData {
        guard let services = ctx.services else { return LockData() }
        let height = try await services.currentHeight()
        let listed = try await ctx.storage.listOutputs(
            ctx.auth,
            try WalletListOutputsRequest(
                basket: OneSatConstants.lockBasket,
                includeTags: true,
                pagination: WalletPagination(limit: 10_000)
            )
        )
        return getLockData(outputs: listed.outputs, currentHeight: height)
    }
}
