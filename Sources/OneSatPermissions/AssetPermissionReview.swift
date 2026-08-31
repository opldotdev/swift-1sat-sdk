import Foundation
import OneSatClient

/// Approval-time trust is evidence from a check performed now, never a persisted asset property.
public enum OneSatPermissionTrustState: String, Codable, Equatable, Sendable {
    case verified
    case unverified
    case mismatch
}

public struct OneSatPermissionTrust: Codable, Equatable, Sendable {
    public let state: OneSatPermissionTrustState
    public let note: String?
    public let resolvedName: String?

    public init(
        state: OneSatPermissionTrustState,
        note: String? = nil,
        resolvedName: String? = nil
    ) {
        self.state = state
        self.note = note
        self.resolvedName = resolvedName
    }
}

/// Pure data that may cross a process boundary before native UI renders it.
public struct OneSatAssetPermissionReview: Codable, Equatable, Sendable {
    public struct Detail: Codable, Equatable, Sendable {
        public let label: String
        public let value: String

        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    public struct Panel: Codable, Equatable, Sendable {
        public enum Variant: String, Codable, Equatable, Sendable {
            case ordinal
            case token
            case value
        }

        public let title: String
        public let subtitle: String?
        public let variant: Variant
        public let details: [Detail]

        public init(
            title: String,
            subtitle: String? = nil,
            variant: Variant,
            details: [Detail] = []
        ) {
            self.title = title
            self.subtitle = subtitle
            self.variant = variant
            self.details = details
        }
    }

    public let originator: String
    public let title: String
    public let summary: String
    public let panels: [Panel]
    public let trust: OneSatPermissionTrust?
    public let bsv21Verification: Bsv21PermissionVerificationContext?

    public init(
        originator: String,
        title: String = "Transaction Request",
        summary: String,
        panels: [Panel],
        trust: OneSatPermissionTrust? = nil,
        bsv21Verification: Bsv21PermissionVerificationContext? = nil
    ) {
        self.originator = originator
        self.title = title
        self.summary = summary
        self.panels = panels
        self.trust = trust
        self.bsv21Verification = bsv21Verification
    }

    public func applying(_ verification: OneSatPermissionTrust) -> Self {
        Self(
            originator: originator,
            title: title,
            summary: summary,
            panels: panels,
            trust: verification,
            bsv21Verification: bsv21Verification
        )
    }
}

/// BSV21 facts captured from wallet-owned input metadata and transaction output scripts.
public struct Bsv21PermissionVerificationContext: Codable, Equatable, Sendable {
    public let tokenID: String
    public let claimedSymbol: String?
    public let inputOutpoints: [String]

    public init(tokenID: String, claimedSymbol: String? = nil, inputOutpoints: [String] = []) {
        self.tokenID = tokenID
        self.claimedSymbol = claimedSymbol
        self.inputOutpoints = inputOutpoints
    }
}

/// Injectable live services; hosts may leave output validation unavailable and still render.
public struct Bsv21PermissionVerificationServices: Sendable {
    public typealias Details = @Sendable (String) async throws -> Bsv21TokenDetails
    public typealias Validate = @Sendable (String, [String]) async throws -> [Bsv21ValidatedOutput]

    public let tokenDetails: Details
    public let validateOutputs: Validate?

    public init(tokenDetails: @escaping Details, validateOutputs: Validate? = nil) {
        self.tokenDetails = tokenDetails
        self.validateOutputs = validateOutputs
    }

    public init(client: Bsv21Client) {
        tokenDetails = { try await client.tokenDetails(tokenID: $0) }
        validateOutputs = { try await client.validateOutputs(tokenID: $0, outpoints: $1, unspent: true) }
    }
}

/// Mirrors the TypeScript prompt verifier: failures are `unverified`, contradictions are mismatch.
public struct Bsv21PermissionVerifier: Sendable {
    private let services: Bsv21PermissionVerificationServices
    private let timeout: Duration

    public init(
        services: Bsv21PermissionVerificationServices,
        timeout: Duration = .seconds(2)
    ) {
        self.services = services
        self.timeout = timeout
    }

    public func verify(_ context: Bsv21PermissionVerificationContext) async -> OneSatPermissionTrust {
        guard let details = await resolve({
            try await services.tokenDetails(context.tokenID)
        }) else {
            return .init(state: .unverified)
        }

        let requestedTokenID = Self.canonicalOutpoint(context.tokenID).lowercased()
        guard Self.canonicalOutpoint(details.tokenID).lowercased() == requestedTokenID,
              Self.canonicalOutpoint(details.token.id).lowercased() == requestedTokenID else {
            return .init(
                state: .mismatch,
                note: "Token details do not match the requested token"
            )
        }

        if details.status.isActive == false {
            return .init(state: .mismatch, note: "Token is not active on the overlay")
        }
        if let claimed = context.claimedSymbol,
           let actual = details.token.symbol,
           claimed.caseInsensitiveCompare(actual) != .orderedSame {
            return .init(
                state: .mismatch,
                note: "Token symbol is \(actual), not \(claimed)"
            )
        }

        if !context.inputOutpoints.isEmpty, let validate = services.validateOutputs {
            guard let outputs = await resolve({
                try await validate(context.tokenID, context.inputOutpoints)
            }) else {
                return .init(state: .unverified)
            }
            let valid = Set(outputs.map { Self.canonicalOutpoint($0.outpoint) })
            let missing = context.inputOutpoints.filter {
                !valid.contains(Self.canonicalOutpoint($0))
            }
            if !missing.isEmpty {
                return .init(
                    state: .mismatch,
                    note: missing.count == 1
                        ? "A spent token output is not valid on the overlay"
                        : "\(missing.count) spent token outputs are not valid on the overlay"
                )
            }
        }

        return .init(state: .verified, resolvedName: details.token.symbol)
    }

    private func resolve<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async -> T? {
        let gate = FirstPermissionVerificationResult<T>()
        let operationTask = Task {
            await gate.finish(try? await operation())
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(for: timeout)
                await gate.finish(nil)
            } catch {
                // The operation won; cancellation only stops this losing timer.
            }
        }
        let result = await gate.value()
        operationTask.cancel()
        timeoutTask.cancel()
        return result
    }

    private static func canonicalOutpoint(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 66 else { return trimmed.replacingOccurrences(of: ".", with: "_") }
        let separator = trimmed.index(trimmed.startIndex, offsetBy: 64)
        guard trimmed[separator] == "." || trimmed[separator] == "_" else {
            return trimmed.replacingOccurrences(of: ".", with: "_")
        }
        return String(trimmed[..<separator]) + "_" + String(trimmed[trimmed.index(after: separator)...])
    }
}

/// Lets a timeout return without structurally awaiting a transport that ignores cancellation.
private actor FirstPermissionVerificationResult<Value: Sendable> {
    private var finished = false
    private var result: Value?
    private var continuation: CheckedContinuation<Value?, Never>?

    func finish(_ value: Value?) {
        guard !finished else { return }
        finished = true
        result = value
        continuation?.resume(returning: value)
        continuation = nil
    }

    func value() async -> Value? {
        if finished { return result }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}
