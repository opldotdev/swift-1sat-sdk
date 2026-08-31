import BSVCore
import BSVCrypto
import BSVKeys
import BSVScript
import BSVWallet
import Foundation
import OneSatTemplates
import ToolboxPermissions

/// Asset storage remains on the standard plain baskets. The deployed TypeScript module routes
/// actions with `p 1sat …` and also defines the asset-specific `bsv21` scheme. BRC-123's published
/// grammar rejects the leading digit in `1sat`, so the protocol-neutral Swift registry uses the
/// internal alias `onesat`; `deployedSchemeLabels` retains the wire labels for interop and must not
/// be persisted as a basket name.
public enum OneSatPermissionAsset: String, CaseIterable, Sendable {
    case oneSat = "1sat"
    case bsv21

    public var registryScheme: PermissionModuleScheme {
        get throws {
            try PermissionModuleScheme(rawValue: self == .oneSat ? "onesat" : "bsv21")
        }
    }

    public var deployedSchemeLabels: [String] {
        switch self {
        case .oneSat: ["1sat"]
        case .bsv21: ["bsv21"]
        }
    }

    public var basket: String { rawValue }

    /// The released TypeScript stack routes createAction through labels shaped as
    /// `p <scheme> <payload>`. They are module dispatch metadata, not action labels a dApp may
    /// acquire a BRC-116 grant for. BRC-123's stricter scheme grammar still governs registry
    /// identifiers; this compatibility normalization is deliberately 1Sat-specific.
    public func canonicalClassification(
        for request: WalletRequest,
        originator: String,
        classifier: WalletPermissionClassifier
    ) -> PermissionClassification {
        guard case .action(.createAction(let action)) = request,
              let labels = action.labels,
              labels.contains(where: isDeployedDispatchLabel) else {
            return classifier.classify(request, originator: originator)
        }
        let ordinaryLabels = labels.filter { !isDeployedDispatchLabel($0) }
        guard let normalized = try? WalletCreateActionRequest(
            description: action.description,
            inputBEEF: action.inputBEEF,
            inputs: action.inputs,
            outputs: action.outputs,
            lockTime: action.lockTime,
            version: action.version,
            labels: ordinaryLabels,
            options: action.options
        ) else {
            return .init(decision: .denied(.unsupportedMethod(request.call.jsonMethodName)))
        }
        return classifier.classify(
            .action(.createAction(normalized)),
            originator: originator
        )
    }

    private func isDeployedDispatchLabel(_ label: String) -> Bool {
        deployedSchemeLabels.contains { scheme in
            let prefix = "p \(scheme) "
            return label.hasPrefix(prefix) && label.utf8.count > prefix.utf8.count
        }
    }

    public static func isBsv21LockingScript(_ bytes: [UInt8]) -> Bool {
        decodeBsv21(bytes) != nil
    }

    fileprivate static func decodeBsv21(_ bytes: [UInt8]) -> BSV21? {
        guard !bytes.isEmpty,
              let script = try? Script(bytes: bytes, maximumByteCount: bytes.count) else { return nil }
        return BSV21.decode(script)
    }
}

/// Wallet-owned input evidence. The resolver supplying this value is responsible for resolving the
/// exact requested outpoint from authenticated wallet storage/BEEF; app tags and descriptions are
/// intentionally absent.
public struct OneSatPermissionResolvedInput: Equatable, Sendable {
    public let outpoint: String
    public let satoshis: UInt64
    public let lockingScript: [UInt8]?

    public init(outpoint: String, satoshis: UInt64, lockingScript: [UInt8]?) {
        self.outpoint = outpoint
        self.satoshis = satoshis
        self.lockingScript = lockingScript
    }
}

public typealias OneSatPermissionInputResolver = @Sendable (
    _ canonicalOutpoints: [String]
) async throws -> [OneSatPermissionResolvedInput]

/// Veto-only adapter from exact BRC-100 arguments to native review data. It does not create grants,
/// invoke a wallet, or treat caller-authored descriptions/tags/customInstructions as transaction
/// facts. BRC-116 authorization remains independently authoritative at the host.
public struct OneSatPermissionModuleAdapter: PermissionModuleHandling, Sendable {
    private let asset: OneSatPermissionAsset
    private let codec: WalletBRC100JSONCodec
    private let verifier: Bsv21PermissionVerifier?
    private let resolveInputs: OneSatPermissionInputResolver?

    public init(
        asset: OneSatPermissionAsset,
        codec: WalletBRC100JSONCodec,
        verifier: Bsv21PermissionVerifier? = nil,
        resolveInputs: OneSatPermissionInputResolver? = nil
    ) {
        self.asset = asset
        self.codec = codec
        self.verifier = verifier
        self.resolveInputs = resolveInputs
    }

    public func review(_ request: PermissionModuleRequest) async throws -> PermissionModuleReview {
        guard request.scheme == (try asset.registryScheme),
              let route = WalletJSONRoute(methodName: request.method) else {
            return .init(decision: .deny)
        }
        let decoded: WalletRequest
        do {
            decoded = try codec.decodeRequest(route: route, from: [UInt8](request.argumentsJSON))
        } catch {
            return .init(decision: .deny)
        }
        guard decoded.call.jsonMethodName == request.method,
              var review = await Self.buildReview(
                asset: asset,
                requestID: request.invocationID,
                request: decoded,
                originator: request.originator.rawValue,
                resolveInputs: resolveInputs
              ) else {
            return .init(decision: .continueAuthorization)
        }

        if review.trust?.state == .unverified,
           let context = review.bsv21Verification,
           let verifier {
            review = review.applying(await verifier.verify(context))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return .init(
            decision: .continueAuthorization,
            serializedReview: try encoder.encode(review)
        )
    }

    private static func buildReview(
        asset: OneSatPermissionAsset,
        requestID: UUID,
        request: WalletRequest,
        originator: String,
        resolveInputs: OneSatPermissionInputResolver?
    ) async -> OneSatAssetPermissionReview? {
        switch request {
        case .action(.createAction(let value)):
            if asset == .bsv21 {
                return await bsv21CreateActionReview(
                    requestID: requestID,
                    value: value,
                    originator: originator,
                    resolveInputs: resolveInputs
                )
            }
            let matching = (value.outputs ?? []).enumerated().filter { _, output in
                output.basket == asset.basket
            }
            guard !matching.isEmpty else { return nil }
            return OneSatAssetPermissionReview(
                requestID: requestID,
                originator: originator,
                summary: "Review 1Sat basket transaction",
                panels: matching.map { index, output in
                    .init(
                        title: "Basket-labeled output",
                        subtitle: "Output \(index)",
                        variant: .ordinal,
                        details: [
                            .init(label: "Satoshis", value: String(output.satoshis)),
                            .init(label: "Basket", value: asset.basket),
                        ]
                    )
                },
                trust: .init(
                    state: .unverified,
                    note: "The 1sat basket label is not proof that an output is an Ordinal"
                )
            )

        case .action(.listOutputs(let value)) where value.basket == asset.basket:
            return OneSatAssetPermissionReview(
                requestID: requestID,
                originator: originator,
                summary: "View \(asset.basket) outputs",
                panels: [.init(
                    title: "Wallet output access",
                    subtitle: value.basket,
                    variant: asset == .bsv21 ? .token : .ordinal,
                    details: [
                        .init(label: "Basket", value: value.basket),
                        .init(
                            label: "Requested filters",
                            value: value.tags.isEmpty ? "All" : value.tags.joined(separator: ", ")
                        ),
                    ]
                )],
                trust: .init(
                    state: .unverified,
                    note: asset == .bsv21
                        ? "A list request has no transaction script to verify"
                        : "The 1sat basket contains wallet-classified outputs; this request has no scripts to verify"
                )
            )

        case .action(.relinquishOutput(let value)) where value.basket == asset.basket:
            return OneSatAssetPermissionReview(
                requestID: requestID,
                originator: originator,
                summary: "Remove a \(asset.basket) output",
                panels: [.init(
                    title: "Remove wallet output",
                    subtitle: value.output.description,
                    variant: asset == .bsv21 ? .token : .ordinal,
                    details: [
                        .init(label: "Basket", value: value.basket),
                        .init(label: "Outpoint", value: value.output.description),
                    ]
                )],
                trust: .init(
                    state: .unverified,
                    note: "The source script is resolved only by the executing wallet"
                )
            )

        case .action(.internalizeAction(let value)):
            let insertions = value.outputs.compactMap { output -> (UInt32, WalletBasketInsertion)? in
                guard case .basketInsertion(let insertion) = output.remittance,
                      insertion.basket == asset.basket else { return nil }
                return (output.outputIndex, insertion)
            }
            guard !insertions.isEmpty else { return nil }
            return OneSatAssetPermissionReview(
                requestID: requestID,
                originator: originator,
                summary: "Add \(asset.basket) outputs to this wallet",
                panels: insertions.map { index, insertion in
                    .init(
                        title: "Add wallet output",
                        subtitle: "Output \(index)",
                        variant: asset == .bsv21 ? .token : .ordinal,
                        details: [.init(label: "Basket", value: insertion.basket)]
                    )
                },
                trust: .init(
                    state: .unverified,
                    note: asset == .bsv21
                        ? "The internalized transaction script is verified by the executing wallet"
                        : "The basket insertion metadata does not prove the internalized output is an Ordinal"
                )
            )
        default:
            return nil
        }
    }

    private struct TokenLeg: Sendable {
        let side: String
        let index: Int
        let outpoint: String?
        let satoshis: UInt64
        let token: BSV21.TokenData
        let scriptSuffix: [UInt8]?
    }

    private static func bsv21CreateActionReview(
        requestID: UUID,
        value: WalletCreateActionRequest,
        originator: String,
        resolveInputs: OneSatPermissionInputResolver?
    ) async -> OneSatAssetPermissionReview? {
        var legs: [TokenLeg] = []
        var panels: [OneSatAssetPermissionReview.Panel] = []
        var contradiction: String?

        for (index, output) in (value.outputs ?? []).enumerated() {
            let decoded = OneSatPermissionAsset.decodeBsv21(output.lockingScript)
            let routedAsToken = output.basket == "bsv21"
                || output.tags.contains(where: { $0.hasPrefix("bsv21:") })
            guard routedAsToken || decoded != nil else {
                panels.append(valueOutputPanel(
                    index: index,
                    satoshis: output.satoshis,
                    lockingScript: output.lockingScript
                ))
                continue
            }
            guard let decoded else {
                contradiction = "An output labeled BSV21 is not a valid BSV21 locking script"
                panels.append(.init(
                    title: "Invalid BSV21 output",
                    subtitle: "Output \(index)",
                    variant: .value,
                    details: scriptDetails(
                        satoshis: output.satoshis,
                        lockingScript: output.lockingScript
                    )
                ))
                continue
            }
            let leg = TokenLeg(
                side: "Output",
                index: index,
                outpoint: nil,
                satoshis: output.satoshis,
                token: decoded.tokenData,
                scriptSuffix: decoded.inscription.scriptSuffix?.bytes
            )
            legs.append(leg)
            panels.append(panel(for: leg))
        }
        guard !legs.isEmpty || contradiction != nil else { return nil }

        var unresolvedInputs = false
        let requestedInputs = (value.inputs ?? []).map { canonicalOutpoint($0.outpoint.description) }
        if !requestedInputs.isEmpty {
            guard let resolveInputs else {
                return finishBsv21Review(
                    requestID: requestID,
                    originator: originator,
                    legs: legs,
                    panels: panels + inputOutpointPanels(requestedInputs),
                    contradiction: contradiction,
                    unresolvedInputs: true
                )
            }
            do {
                let resolved = try await resolveInputs(requestedInputs)
                let grouped = Dictionary(grouping: resolved) { canonicalOutpoint($0.outpoint) }
                if grouped.keys.contains(where: { !requestedInputs.contains($0) })
                    || grouped.values.contains(where: { $0.count != 1 }) {
                    contradiction = "Wallet input metadata does not match the requested outpoints"
                }
                for (index, outpoint) in requestedInputs.enumerated() {
                    guard let metadata = grouped[outpoint]?.first,
                          let bytes = metadata.lockingScript else {
                        unresolvedInputs = true
                        panels.append(inputOutpointPanel(outpoint))
                        continue
                    }
                    guard let decoded = OneSatPermissionAsset.decodeBsv21(bytes) else {
                        // Resolved non-token funding inputs are legitimate and are not token legs.
                        panels.append(.init(
                            title: "Value input",
                            subtitle: "Input \(index)",
                            variant: .value,
                            details: [
                                .init(label: "Outpoint", value: outpoint),
                                .init(label: "Satoshis", value: String(metadata.satoshis)),
                            ] + lockingScriptDetails(bytes)
                        ))
                        continue
                    }
                    let leg = TokenLeg(
                        side: "Input",
                        index: index,
                        outpoint: outpoint,
                        satoshis: metadata.satoshis,
                        token: decoded.tokenData,
                        scriptSuffix: decoded.inscription.scriptSuffix?.bytes
                    )
                    legs.append(leg)
                    panels.append(panel(for: leg))
                }
            } catch {
                unresolvedInputs = true
                panels.append(contentsOf: inputOutpointPanels(requestedInputs))
            }
        }

        return finishBsv21Review(
            requestID: requestID,
            originator: originator,
            legs: legs,
            panels: panels,
            contradiction: contradiction,
            unresolvedInputs: unresolvedInputs
        )
    }

    private static func finishBsv21Review(
        requestID: UUID,
        originator: String,
        legs: [TokenLeg],
        panels: [OneSatAssetPermissionReview.Panel],
        contradiction: String?,
        unresolvedInputs: Bool
    ) -> OneSatAssetPermissionReview {
        let explicitIDs = legs.compactMap { $0.token.tokenID.flatMap(canonicalTokenID) }
        let malformedID = legs.contains { leg in
            guard let id = leg.token.tokenID else { return false }
            return canonicalTokenID(id) == nil
        }
        let tokenIDs = Set(explicitIDs)
        let deployLegs = legs.filter {
            $0.token.operation == .deployMint || $0.token.operation == .deployAuth
        }
        let existingTokenOutputs = legs.filter {
            $0.side == "Output"
                && $0.token.operation != .deployMint
                && $0.token.operation != .deployAuth
        }
        let hasTokenInput = legs.contains { $0.side == "Input" && $0.token.tokenID != nil }
        let missingRequiredTokenInput = !existingTokenOutputs.isEmpty && !hasTokenInput
        var mismatch = contradiction
        if malformedID { mismatch = "A BSV21 script contains an invalid token ID" }
        if tokenIDs.count > 1 { mismatch = "BSV21 inputs and outputs refer to different tokens" }
        if !deployLegs.isEmpty, !tokenIDs.isEmpty {
            mismatch = "A deployment cannot be verified as a leg of an existing token"
        }

        let symbols = Set(legs.compactMap(\.token.symbol).map { $0.lowercased() })
        if symbols.count > 1 { mismatch = "BSV21 deployment symbols disagree" }

        let context: Bsv21PermissionVerificationContext?
        if mismatch == nil,
           !unresolvedInputs,
           !missingRequiredTokenInput,
           let tokenID = tokenIDs.first {
            context = .init(
                tokenID: tokenID,
                claimedSymbol: legs.compactMap(\.token.symbol).first,
                inputOutpoints: legs.compactMap { $0.side == "Input" ? $0.outpoint : nil }
            )
        } else {
            context = nil
        }

        let trust: OneSatPermissionTrust
        if let mismatch {
            trust = .init(state: .mismatch, note: mismatch)
        } else if unresolvedInputs {
            trust = .init(state: .unverified, note: "One or more input scripts could not be resolved from wallet-owned metadata")
        } else if missingRequiredTokenInput {
            trust = .init(state: .unverified, note: "An existing-token operation has no verified BSV21 input")
        } else if !deployLegs.isEmpty, tokenIDs.isEmpty {
            trust = .init(state: .unverified, note: "A deployment token ID is assigned only after the transaction is created")
        } else if context == nil {
            trust = .init(state: .unverified, note: "No existing token ID is available for overlay verification")
        } else {
            trust = .init(state: .unverified)
        }

        return OneSatAssetPermissionReview(
            requestID: requestID,
            originator: originator,
            summary: "Review BSV21 transaction",
            panels: panels,
            trust: trust,
            bsv21Verification: context
        )
    }

    private static func panel(for leg: TokenLeg) -> OneSatAssetPermissionReview.Panel {
        var details: [OneSatAssetPermissionReview.Detail] = [
            .init(label: "Operation", value: leg.token.operation.rawValue),
            .init(label: "Satoshis", value: String(leg.satoshis)),
        ]
        if let tokenID = leg.token.tokenID {
            details.append(.init(label: "Token ID", value: canonicalTokenID(tokenID) ?? tokenID))
        }
        if let amount = leg.token.amount { details.append(.init(label: "Token amount", value: amount)) }
        if let symbol = leg.token.symbol { details.append(.init(label: "Symbol", value: symbol)) }
        if let outpoint = leg.outpoint { details.append(.init(label: "Outpoint", value: outpoint)) }
        if let suffix = leg.scriptSuffix {
            if let recipient = p2pkhRecipient(from: suffix) {
                details.append(.init(label: "Recipient", value: recipient))
            }
            details.append(.init(label: "Recipient script", value: hex(suffix)))
        } else {
            details.append(.init(label: "Recipient script", value: "None (data-only)"))
        }
        return .init(
            title: "BSV21 \(leg.side.lowercased())",
            subtitle: "\(leg.side) \(leg.index)",
            variant: .token,
            details: details
        )
    }

    private static func inputOutpointPanels(_ outpoints: [String]) -> [OneSatAssetPermissionReview.Panel] {
        outpoints.map(inputOutpointPanel)
    }

    private static func valueOutputPanel(
        index: Int,
        satoshis: UInt64,
        lockingScript: [UInt8]
    ) -> OneSatAssetPermissionReview.Panel {
        .init(
            title: "Value output",
            subtitle: "Output \(index)",
            variant: .value,
            details: scriptDetails(satoshis: satoshis, lockingScript: lockingScript)
        )
    }

    private static func scriptDetails(
        satoshis: UInt64,
        lockingScript: [UInt8]
    ) -> [OneSatAssetPermissionReview.Detail] {
        [.init(label: "Satoshis", value: String(satoshis))]
            + lockingScriptDetails(lockingScript)
    }

    private static func lockingScriptDetails(
        _ lockingScript: [UInt8]
    ) -> [OneSatAssetPermissionReview.Detail] {
        var details: [OneSatAssetPermissionReview.Detail] = []
        if let recipient = p2pkhRecipient(from: lockingScript) {
            details.append(.init(label: "Recipient", value: recipient))
        }
        if lockingScript.count <= 128 {
            details.append(.init(label: "Locking script", value: hex(lockingScript)))
        } else {
            details.append(.init(label: "Locking script bytes", value: String(lockingScript.count)))
            details.append(.init(
                label: "Locking script SHA-256",
                value: hex(BSVHashing.sha256(lockingScript).bytes)
            ))
        }
        return details
    }

    private static func inputOutpointPanel(_ outpoint: String) -> OneSatAssetPermissionReview.Panel {
        .init(
            title: "Unresolved input",
            subtitle: "Input",
            variant: .value,
            details: [.init(label: "Outpoint", value: outpoint)]
        )
    }

    private static func canonicalTokenID(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 66 else { return nil }
        let separator = trimmed.index(trimmed.startIndex, offsetBy: 64)
        let transactionID = String(trimmed[..<separator])
        let outputIndex = String(trimmed[trimmed.index(after: separator)...])
        guard trimmed[separator] == "." || trimmed[separator] == "_",
              transactionID.utf8.count == 64,
              transactionID.utf8.allSatisfy({
                  (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
              }),
              let index = UInt32(outputIndex),
              !outputIndex.isEmpty,
              outputIndex.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return transactionID.lowercased() + "_" + String(index)
    }

    private static func p2pkhRecipient(from suffix: [UInt8]) -> String? {
        guard suffix.count >= 25,
              let script = try? Script(
                bytes: Array(suffix.prefix(25)),
                maximumByteCount: 25
              ),
              let bytes = script.publicKeyHash,
              let hash = try? Hash160(bytes) else { return nil }
        return Address(publicKeyHash: hash, network: .mainnet).description
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func canonicalOutpoint(_ value: String) -> String {
        canonicalTokenID(value) ?? value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".", with: "_")
    }
}
