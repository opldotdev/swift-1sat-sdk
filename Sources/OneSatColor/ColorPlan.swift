import Foundation
import BSVCore

/// A BRC-207 version 1 action plan, carried in action labels as
/// `p color plan <partIndex> <partCount> <200-hex chunk>`. Port of the color module's
/// `ColorPlan.ts`: the same validation, and the same JSON member order as the plans
/// `@1sat/actions` builds, so the labels are byte-identical.
public struct ColorPlan: Equatable, Sendable {
    public static let labelPrefix = "p color plan "
    static let chunkHexLength = 200
    static let maxPlanBytes = 16 * 1024 * 1024
    static let maxPlanParts = (maxPlanBytes * 2 + chunkHexLength - 1) / chunkHexLength

    public enum Operation: String, CaseIterable, Sendable {
        case transfer, burn
        case deployFixed = "deploy-fixed"
        case deployAuthority = "deploy-authority"
        case mint
        case authoritySplit = "authority-split"
        case authorityCombine = "authority-combine"
        case authorityTransfer = "authority-transfer"
        case authorityEnd = "authority-end"
        case resource
    }

    /// Key derivation facts of a managed output; the asset is `ISSUE` for a deploy output.
    public struct Remittance: Equatable, Sendable {
        public var outputIndex: UInt32
        public var asset: ColorAssetSelector
        public var derivationPrefix: String
        public var derivationSuffix: String
        public var senderIdentityKey: String

        public init(outputIndex: UInt32, asset: ColorAssetSelector, derivationPrefix: String, derivationSuffix: String, senderIdentityKey: String) {
            self.outputIndex = outputIndex; self.asset = asset
            self.derivationPrefix = derivationPrefix; self.derivationSuffix = derivationSuffix
            self.senderIdentityKey = senderIdentityKey
        }
    }

    public struct AssetOperation: Equatable, Sendable {
        public var asset: ColorAssetSelector
        public var operation: Operation
        public init(asset: ColorAssetSelector, operation: Operation) { self.asset = asset; self.operation = operation }
    }

    public struct InputPosition: Equatable, Sendable {
        public var outpoint: String
        public var index: UInt32
        public init(outpoint: String, index: UInt32) { self.outpoint = outpoint; self.index = index }
    }

    public struct ChangePosition: Equatable, Sendable {
        /// nil for satoshi change.
        public var asset: ColorAssetID?
        public var index: UInt32
        public init(asset: ColorAssetID?, index: UInt32) { self.asset = asset; self.index = index }
    }

    public struct SighashOverride: Equatable, Sendable {
        public var outpoint: String
        public var sighashType: UInt32
        public init(outpoint: String, sighashType: UInt32) { self.outpoint = outpoint; self.sighashType = sighashType }
    }

    public var assets: [ColorAssetSelector]
    public var ownedOutputs: [Remittance]
    public var operations: [AssetOperation]
    public var inputPositions: [InputPosition]
    public var changePositions: [ChangePosition]
    public var sighashTypes: [SighashOverride]
    /// Profile data by profile, then asset (or `ISSUE`). Kept as JSON; Swift writes none.
    public var profileData: [(String, StrictJSON)]?

    public init(
        assets: [ColorAssetSelector], ownedOutputs: [Remittance] = [], operations: [AssetOperation] = [],
        inputPositions: [InputPosition] = [], changePositions: [ChangePosition] = [],
        sighashTypes: [SighashOverride] = [], profileData: [(String, StrictJSON)]? = nil
    ) {
        self.assets = assets; self.ownedOutputs = ownedOutputs; self.operations = operations
        self.inputPositions = inputPositions; self.changePositions = changePositions
        self.sighashTypes = sighashTypes; self.profileData = profileData
    }

    public static func == (lhs: ColorPlan, rhs: ColorPlan) -> Bool { lhs.json == rhs.json }

    /// The plan as `JSON.stringify` writes the object `@1sat/actions` builds.
    public var json: StrictJSON {
        var members: [(String, StrictJSON)] = [
            ("version", .number(1)),
            ("assets", .array(assets.map { .string($0.description) })),
            ("ownedOutputs", .array(ownedOutputs.map { r in .object([
                ("outputIndex", .number(Double(r.outputIndex))),
                ("assetId", .string(r.asset.description)),
                ("derivationPrefix", .string(r.derivationPrefix)),
                ("derivationSuffix", .string(r.derivationSuffix)),
                ("senderIdentityKey", .string(r.senderIdentityKey)),
            ]) })),
            ("operations", .array(operations.map { .object([
                ("assetId", .string($0.asset.description)), ("operation", .string($0.operation.rawValue)),
            ]) })),
            ("inputPositions", .array(inputPositions.map { .object([
                ("outpoint", .string($0.outpoint)), ("index", .number(Double($0.index))),
            ]) })),
            ("changePositions", .array(changePositions.map { .object([
                ("assetId", $0.asset.map { .string($0.description) } ?? .null), ("index", .number(Double($0.index))),
            ]) })),
            ("sighashTypes", .array(sighashTypes.map { .object([
                ("outpoint", .string($0.outpoint)), ("sighashType", .number(Double($0.sighashType))),
            ]) })),
        ]
        if let profileData { members.append(("profileData", .object(profileData))) }
        return .object(members)
    }

    /// Splits the validated plan into `p color plan <i> <n> <hex>` labels.
    public func labels() throws -> [String] {
        let bytes = Array(json.serialized.utf8)
        guard bytes.count <= Self.maxPlanBytes else { throw ColorError.planTooLarge }
        _ = try Self.parse(StrictJSON.parse(bytes: bytes, label: "plan"))
        let hex = Array(Hex.encode(bytes).utf8)
        let count = (hex.count + Self.chunkHexLength - 1) / Self.chunkHexLength
        return (0..<count).map { i in
            let chunk = hex[(i * Self.chunkHexLength)..<min(hex.count, (i + 1) * Self.chunkHexLength)]
            return "\(Self.labelPrefix)\(i) \(count) \(String(decoding: chunk, as: UTF8.self))"
        }
    }

    /// Reassembles the plan from its labels; nil when no plan label is present.
    public static func fromLabels(_ labels: [String]) throws -> ColorPlan? {
        let parts = labels.filter { $0.hasPrefix(labelPrefix) }
        guard !parts.isEmpty else { return nil }
        var count: Int?
        var chunks: [Int: String] = [:]
        for label in parts {
            let fields = label.dropFirst(labelPrefix.count).split(separator: " ", omittingEmptySubsequences: false)
            guard fields.count == 3,
                  let index = canonicalInt(fields[0], allowZero: true),
                  let partCount = canonicalInt(fields[1], allowZero: false),
                  !fields[2].isEmpty, fields[2].allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else {
                throw ColorError.invalid("p color plan label")
            }
            let hex = String(fields[2])
            if partCount > maxPlanParts { throw ColorError.planTooLarge }
            if let count, count != partCount { throw ColorError.invalid("inconsistent plan part counts") }
            count = partCount
            guard index < partCount else { throw ColorError.invalid("plan part index out of range") }
            guard chunks[index] == nil else { throw ColorError.invalid("duplicate plan part") }
            guard hex.count % 2 == 0, hex.count <= chunkHexLength else { throw ColorError.invalid("plan chunk") }
            guard index == partCount - 1 || hex.count == chunkHexLength else { throw ColorError.invalid("short nonfinal plan chunk") }
            chunks[index] = hex
        }
        guard let count, parts.count == count else { throw ColorError.invalid("missing plan part") }
        let hex = (0..<count).map { chunks[$0]! }.joined()
        guard hex.count <= maxPlanBytes * 2 else { throw ColorError.planTooLarge }
        return try parse(StrictJSON.parse(bytes: Hex.decode(hex, maximumDecodedByteCount: maxPlanBytes), label: "plan"))
    }

    /// `(0|[1-9]\d{0,9})` / `([1-9]\d{0,9})`.
    private static func canonicalInt(_ text: Substring, allowZero: Bool) -> Int? {
        guard !text.isEmpty, text.count <= 10, text.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        if text == "0" { return allowZero ? 0 : nil }
        guard !text.hasPrefix("0") else { return nil }
        return Int(text)
    }

    // MARK: - Validation (parsePlan)

    static func parse(_ value: StrictJSON) throws -> ColorPlan {
        let object = try value.object("plan")
        try StrictJSON.exactMembers(object, required: ["version", "assets", "ownedOutputs", "operations",
            "inputPositions", "changePositions", "sighashTypes"], optional: ["profileData"], label: "plan")
        guard object[member: "version"] == .number(1) else { throw ColorError.invalid("plan version must be 1") }
        let assets = try object[member: "assets"]!.array("plan.assets").map { try ColorAssetSelector($0.string("plan.assets")) }
        try unique(assets.map(\.description), "plan asset")
        let operations = try object[member: "operations"]!.array("plan.operations").enumerated().map { i, item in
            let o = try item.object("plan.operations[\(i)]")
            try StrictJSON.exactMembers(o, required: ["assetId", "operation"], label: "plan.operations[\(i)]")
            guard case .string(let name)? = o[member: "operation"], let op = Operation(rawValue: name) else {
                throw ColorError.invalid("plan.operations[\(i)] has an unknown operation")
            }
            return AssetOperation(asset: try ColorAssetSelector(o[member: "assetId"]!.string("assetId")), operation: op)
        }
        try unique(operations.map { "\($0.asset) \($0.operation.rawValue)" }, "plan operation")
        let inputs = try object[member: "inputPositions"]!.array("plan.inputPositions").enumerated().map { i, item in
            let o = try item.object("plan.inputPositions[\(i)]")
            try StrictJSON.exactMembers(o, required: ["outpoint", "index"], label: "plan.inputPositions[\(i)]")
            let outpoint = try o[member: "outpoint"]!.string("outpoint")
            try validateOutpoint(outpoint)
            return InputPosition(outpoint: outpoint, index: try o[member: "index"]!.uint32("plan.inputPositions[\(i)].index"))
        }
        try unique(inputs.map(\.outpoint), "plan input position outpoint")
        try unique(inputs.map { String($0.index) }, "plan input position index")
        let changes = try object[member: "changePositions"]!.array("plan.changePositions").enumerated().map { i, item in
            let o = try item.object("plan.changePositions[\(i)]")
            try StrictJSON.exactMembers(o, required: ["assetId", "index"], label: "plan.changePositions[\(i)]")
            let asset: ColorAssetID? = o[member: "assetId"] == .null ? nil : try ColorAssetID(o[member: "assetId"]!.string("assetId"))
            return ChangePosition(asset: asset, index: try o[member: "index"]!.uint32("plan.changePositions[\(i)].index"))
        }
        try unique(changes.map { $0.asset?.description ?? "\u{0}null" }, "plan change position asset")
        try unique(changes.map { String($0.index) }, "plan change position index")
        let sighashes = try object[member: "sighashTypes"]!.array("plan.sighashTypes").enumerated().map { i, item in
            let o = try item.object("plan.sighashTypes[\(i)]")
            try StrictJSON.exactMembers(o, required: ["outpoint", "sighashType"], label: "plan.sighashTypes[\(i)]")
            let outpoint = try o[member: "outpoint"]!.string("outpoint")
            try validateOutpoint(outpoint)
            let type = try o[member: "sighashType"]!.uint32("plan.sighashTypes[\(i)].sighashType")
            guard type <= 255 else { throw ColorError.invalid("plan.sighashTypes[\(i)].sighashType must be in 0..255") }
            return SighashOverride(outpoint: outpoint, sighashType: type)
        }
        try unique(sighashes.map(\.outpoint), "plan sighash override outpoint")
        let owned = try object[member: "ownedOutputs"]!.array("plan.ownedOutputs").enumerated().map { i, item in
            try parseRemittance(item, label: "plan.ownedOutputs[\(i)]")
        }
        try unique(owned.map { String($0.outputIndex) }, "plan.ownedOutputs output index")
        var profileData: [(String, StrictJSON)]?
        if let data = object[member: "profileData"] {
            let profiles = try data.object("plan.profileData")
            for (profile, byAsset) in profiles {
                for (asset, _) in try byAsset.object("plan.profileData.\(profile)") { _ = try ColorAssetSelector(asset) }
            }
            profileData = profiles
        }
        let plan = ColorPlan(assets: assets, ownedOutputs: owned, operations: operations, inputPositions: inputs,
            changePositions: changes, sighashTypes: sighashes, profileData: profileData)
        let referenced = owned.map(\.asset) + operations.map(\.asset) + changes.compactMap { $0.asset.map(ColorAssetSelector.asset) }
        for asset in referenced where !assets.contains(asset) {
            throw ColorError.invalid("plan references \(asset) outside plan.assets")
        }
        if assets.contains(.issue), operations.filter({ $0.operation.rawValue.hasPrefix("deploy-") }).count != 1 {
            throw ColorError.invalid("a deploy plan has exactly one deploy operation")
        }
        return plan
    }

    static func parseRemittance(_ value: StrictJSON, label: String) throws -> Remittance {
        let o = try value.object(label)
        try StrictJSON.exactMembers(o, required: ["outputIndex", "assetId", "derivationPrefix", "derivationSuffix", "senderIdentityKey"], label: label)
        let prefix = try o[member: "derivationPrefix"]!.string("\(label).derivationPrefix")
        let suffix = try o[member: "derivationSuffix"]!.string("\(label).derivationSuffix")
        try ColorIdentifiers.validateRemittance(prefix)
        try ColorIdentifiers.validateRemittance(suffix)
        let sender = try o[member: "senderIdentityKey"]!.string("\(label).senderIdentityKey")
        try ColorIdentifiers.validateIdentityKey(sender)
        let remittance = Remittance(
            outputIndex: try o[member: "outputIndex"]!.uint32("\(label).outputIndex"),
            asset: try ColorAssetSelector(o[member: "assetId"]!.string("\(label).assetId")),
            derivationPrefix: prefix, derivationSuffix: suffix, senderIdentityKey: sender)
        _ = try ColorIdentifiers.protocolName(remittance.asset, derivationPrefix: prefix, derivationSuffix: suffix)
        return remittance
    }

    /// `<64 hex>.<canonical uint32>`.
    static func validateOutpoint(_ text: String) throws {
        guard let dot = text.firstIndex(of: ".") else { throw ColorError.invalid("outpoint") }
        do { _ = try ColorAssetID(txid: String(text[..<dot]), voutText: String(text[text.index(after: dot)...])) }
        catch { throw ColorError.invalid("outpoint") }
    }

    private static func unique(_ values: [String], _ label: String) throws {
        guard Set(values).count == values.count else { throw ColorError.invalid("duplicate \(label)") }
    }
}
