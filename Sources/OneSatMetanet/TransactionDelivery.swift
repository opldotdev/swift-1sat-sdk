import Foundation
import OneSatCBOR

/// BRC-232 transaction delivery: a DAG-CBOR body behind a two-header MIME entity, ported from
/// `actions/src/metanet/delivery.ts`. Parsing is strict in the same places: exact members,
/// outputs strictly increasing by index, a memo of at most 2000 UTF-8 bytes, a header block of
/// at most 8 KiB, an entity of at most 32 MiB, and no repeated header.
public struct TransactionDelivery: Equatable, Sendable {
    public static let contentType = "application/vnd.metanet.transaction+cbor"
    public static let mimeHeader =
        "Content-Type: \(contentType)\r\nContent-Transfer-Encoding: binary\r\n\r\n"
    public static let maximumHeaderBytes = 8 * 1024
    public static let maximumEntityBytes = 32 * 1024 * 1024
    public static let maximumMemoBytes = 2000

    public enum Output: Equatable, Sendable {
        case walletPayment(
            outputIndex: UInt32, derivationPrefix: String, derivationSuffix: String,
            senderIdentityKey: [UInt8]
        )
        case basketInsertion(
            outputIndex: UInt32, basket: String, customInstructions: String, tags: [String]?
        )

        public var outputIndex: UInt32 {
            switch self {
            case .walletPayment(let index, _, _, _), .basketInsertion(let index, _, _, _): index
            }
        }
    }

    public struct Lifecycle: Equatable, Sendable {
        public var statement: DagCborMap
        public var signer: String
        public var signature: String

        public init(statement: DagCborMap, signer: String, signature: String) {
            self.statement = statement
            self.signer = signer
            self.signature = signature
        }
    }

    /// Byte order as on the wire: the txid's internal byte order is what the reference stores,
    /// `Utils.toHex(txid)` being the display txid. So these are the display-order bytes.
    public var txid: [UInt8]
    public var beef: [UInt8]
    public var outputs: [Output]
    public var lifecycles: [Lifecycle]
    public var memo: String?
    public var profileData: DagCborValue?

    public init(
        txid: [UInt8], beef: [UInt8], outputs: [Output], lifecycles: [Lifecycle] = [],
        memo: String? = nil, profileData: DagCborValue? = nil
    ) {
        self.txid = txid
        self.beef = beef
        self.outputs = outputs
        self.lifecycles = lifecycles
        self.memo = memo
        self.profileData = profileData
    }

    // MARK: - Encoding

    /// Validates, then encodes the body canonically.
    public func encoded() throws -> [UInt8] {
        let value = try cborValue()
        // Round-tripping through the parser applies every check the receiver will.
        _ = try Self.parse(value)
        return try DagCbor.encode(value)
    }

    /// The MIME entity: the fixed header block, then the body.
    public func mime() throws -> [UInt8] {
        Array(Self.mimeHeader.utf8) + (try encoded())
    }

    func cborValue() throws -> DagCborValue {
        var entries: [(key: String, value: DagCborValue)] = [
            ("version", .unsigned(1)),
            ("txid", .bytes(txid)),
            ("beef", .bytes(beef)),
            ("outputs", .array(try outputs.map(Self.encode))),
            ("lifecycles", .array(try lifecycles.map {
                .map(try DagCborMap([
                    ("statement", .map($0.statement)),
                    ("signer", .text($0.signer)),
                    ("signature", .text($0.signature)),
                ]))
            })),
        ]
        if let memo { entries.append(("memo", .text(memo))) }
        if let profileData { entries.append(("profileData", profileData)) }
        return .map(try DagCborMap(entries))
    }

    static func encode(_ output: Output) throws -> DagCborValue {
        switch output {
        case let .walletPayment(index, prefix, suffix, sender):
            return .map(try DagCborMap([
                ("outputIndex", .unsigned(UInt64(index))),
                ("protocol", .text("wallet payment")),
                ("paymentRemittance", .map(try DagCborMap([
                    ("derivationPrefix", .text(prefix)),
                    ("derivationSuffix", .text(suffix)),
                    ("senderIdentityKey", .bytes(sender)),
                ]))),
            ]))
        case let .basketInsertion(index, basket, instructions, tags):
            var remittance: [(key: String, value: DagCborValue)] = [
                ("basket", .text(basket)), ("customInstructions", .text(instructions)),
            ]
            if let tags { remittance.append(("tags", .array(tags.map { .text($0) }))) }
            return .map(try DagCborMap([
                ("outputIndex", .unsigned(UInt64(index))),
                ("protocol", .text("basket insertion")),
                ("insertionRemittance", .map(try DagCborMap(remittance))),
            ]))
        }
    }

    // MARK: - Decoding

    /// Decodes a body. Non-canonical DAG-CBOR is refused, as the reference's decoder does.
    public static func decode(_ body: [UInt8]) throws -> TransactionDelivery {
        let value: DagCborValue
        do {
            value = try DagCbor.decode(
                body, options: .init(strictUTF8: true, requireCanonicalMapOrder: true)
            )
        } catch {
            throw MetanetError.delivery("BRC-232: the body is not canonical DAG-CBOR (\(error))")
        }
        return try parse(value)
    }

    /// The body of a MIME entity, after checking its headers.
    public static func body(ofEntity entity: [UInt8]) throws -> [UInt8] {
        guard entity.count <= maximumEntityBytes else {
            throw MetanetError.delivery("BRC-232: the MIME entity exceeds 32 MiB")
        }
        var end = -1
        var index = 0
        while index + 3 < entity.count, index <= maximumHeaderBytes {
            if entity[index] == 13, entity[index + 1] == 10,
               entity[index + 2] == 13, entity[index + 3] == 10 {
                end = index
                break
            }
            index += 1
        }
        guard end >= 0 else { throw MetanetError.delivery("BRC-232: no MIME header block") }

        let headerText = String(decoding: entity[0..<end], as: UTF8.self)
        var seen: [String: String] = [:]
        for line in headerText.components(separatedBy: "\r\n") {
            guard let (name, value) = headerLine(line) else {
                throw MetanetError.delivery("BRC-232: malformed MIME header")
            }
            let key = name.lowercased()
            guard seen[key] == nil else {
                throw MetanetError.delivery("BRC-232: duplicate MIME header \(name)")
            }
            seen[key] = value
        }
        guard seen["content-type"]?.lowercased() == contentType else {
            throw MetanetError.delivery(
                "BRC-232: Content-Type must be \(contentType) with no parameters"
            )
        }
        guard seen["content-transfer-encoding"]?.lowercased() == "binary" else {
            throw MetanetError.delivery("BRC-232: Content-Transfer-Encoding must be binary")
        }
        return Array(entity[(end + 4)...])
    }

    /// `^([!-9;-~]+):[ \t]*(.*?)[ \t]*$`: a name of printable ASCII other than `:`, then the
    /// value with surrounding spaces and tabs removed.
    static func headerLine(_ line: String) -> (String, String)? {
        let scalars = Array(line.unicodeScalars)
        guard let colon = scalars.firstIndex(of: ":"), colon > 0 else { return nil }
        let nameScalars = scalars[..<colon]
        guard nameScalars.allSatisfy({ (0x21...0x7e).contains($0.value) && $0 != ":" }) else {
            return nil
        }
        // JavaScript's `.` does not match line terminators.
        let valueScalars = scalars[(colon + 1)...]
        guard !valueScalars.contains(where: {
            [0x0a, 0x0d, 0x2028, 0x2029].contains($0.value)
        }) else { return nil }
        var value = String(String.UnicodeScalarView(valueScalars))
        while let first = value.unicodeScalars.first, first == " " || first == "\t" {
            value.unicodeScalars.removeFirst()
        }
        while let last = value.unicodeScalars.last, last == " " || last == "\t" {
            value.unicodeScalars.removeLast()
        }
        return (String(String.UnicodeScalarView(nameScalars)), value)
    }

    static func parse(_ value: DagCborValue) throws -> TransactionDelivery {
        guard case .map(let map) = value else { throw invalid("the body must be a map") }
        try exactMembers(
            map, required: ["version", "txid", "beef", "outputs", "lifecycles"],
            allowed: ["version", "txid", "beef", "outputs", "lifecycles", "memo", "profileData"],
            what: "the body"
        )
        guard map["version"] == .unsigned(1) else { throw invalid("version must be 1") }
        guard let outputRows = map["outputs"]?.arrayValue, !outputRows.isEmpty else {
            throw invalid("outputs must be a nonempty array")
        }
        let outputs = try outputRows.enumerated().map { try parseOutput($0.element, $0.offset) }
        for index in outputs.indices.dropFirst()
        where outputs[index].outputIndex <= outputs[index - 1].outputIndex {
            throw invalid("outputs must be strictly increasing by outputIndex")
        }
        guard let lifecycleRows = map["lifecycles"]?.arrayValue else {
            throw invalid("lifecycles must be an array")
        }
        var delivery = TransactionDelivery(
            txid: try bytes(map["txid"], "txid", length: 32),
            beef: try bytes(map["beef"], "beef"),
            outputs: outputs,
            lifecycles: try lifecycleRows.enumerated().map { try parseLifecycle($0.element, $0.offset) }
        )
        if let memoValue = map["memo"] {
            let memo = try text(memoValue, "memo")
            guard memo.utf8.count <= maximumMemoBytes else {
                throw invalid("memo exceeds 2000 UTF-8 bytes")
            }
            delivery.memo = memo
        }
        delivery.profileData = map["profileData"]
        return delivery
    }

    static func parseOutput(_ value: DagCborValue, _ index: Int) throws -> Output {
        let what = "outputs[\(index)]"
        guard case .map(let map) = value else { throw invalid("\(what) must be a map") }
        let outputIndex = try uint32(map["outputIndex"], "\(what).outputIndex")
        switch map["protocol"] {
        case .text("wallet payment")?:
            let members = ["outputIndex", "protocol", "paymentRemittance"]
            try exactMembers(map, required: members, allowed: members, what: what)
            guard case .map(let remittance)? = map["paymentRemittance"] else {
                throw invalid("\(what).paymentRemittance must be a map")
            }
            let fields = ["derivationPrefix", "derivationSuffix", "senderIdentityKey"]
            try exactMembers(
                remittance, required: fields, allowed: fields, what: "\(what).paymentRemittance"
            )
            return .walletPayment(
                outputIndex: outputIndex,
                derivationPrefix: try text(remittance["derivationPrefix"], "\(what).derivationPrefix"),
                derivationSuffix: try text(remittance["derivationSuffix"], "\(what).derivationSuffix"),
                senderIdentityKey: try bytes(
                    remittance["senderIdentityKey"], "\(what).senderIdentityKey", length: 33
                )
            )
        case .text("basket insertion")?:
            let members = ["outputIndex", "protocol", "insertionRemittance"]
            try exactMembers(map, required: members, allowed: members, what: what)
            guard case .map(let remittance)? = map["insertionRemittance"] else {
                throw invalid("\(what).insertionRemittance must be a map")
            }
            try exactMembers(
                remittance, required: ["basket", "customInstructions"],
                allowed: ["basket", "customInstructions", "tags"],
                what: "\(what).insertionRemittance"
            )
            var tags: [String]?
            if let tagValue = remittance["tags"] {
                guard let rows = tagValue.arrayValue else {
                    throw invalid("\(what).tags must be an array")
                }
                tags = try rows.enumerated().map { try text($0.element, "\(what).tags[\($0.offset)]") }
            }
            return .basketInsertion(
                outputIndex: outputIndex,
                basket: try text(remittance["basket"], "\(what).basket"),
                customInstructions: try text(
                    remittance["customInstructions"], "\(what).customInstructions"
                ),
                tags: tags
            )
        default:
            throw invalid("\(what) has an unsupported protocol \(describe(map["protocol"]))")
        }
    }

    static func parseLifecycle(_ value: DagCborValue, _ index: Int) throws -> Lifecycle {
        let what = "lifecycles[\(index)]"
        guard case .map(let map) = value else { throw invalid("\(what) must be a map") }
        let members = ["statement", "signer", "signature"]
        try exactMembers(map, required: members, allowed: members, what: what)
        guard case .map(let statement)? = map["statement"] else {
            throw invalid("\(what).statement must be a map")
        }
        return Lifecycle(
            statement: statement,
            signer: try text(map["signer"], "\(what).signer"),
            signature: try text(map["signature"], "\(what).signature")
        )
    }

    // MARK: - Helpers

    static func invalid(_ reason: String) -> MetanetError { .delivery("BRC-232: \(reason)") }

    static func exactMembers(
        _ map: DagCborMap, required: [String], allowed: [String], what: String
    ) throws {
        for key in map.keys where !allowed.contains(key) {
            throw invalid("\(what) has an unknown member \(key)")
        }
        for key in required where map[key] == nil {
            throw invalid("\(what) lacks \(key)")
        }
    }

    static func bytes(_ value: DagCborValue?, _ what: String, length: Int? = nil) throws -> [UInt8] {
        guard let bytes = value?.bytesValue, length == nil || bytes.count == length else {
            throw invalid(
                "\(what) must be a byte string\(length.map { " of \($0) bytes" } ?? "")"
            )
        }
        return bytes
    }

    static func text(_ value: DagCborValue?, _ what: String) throws -> String {
        guard let text = value?.textValue else { throw invalid("\(what) must be text") }
        return text
    }

    static func uint32(_ value: DagCborValue?, _ what: String) throws -> UInt32 {
        guard case .unsigned(let number)? = value, let narrowed = UInt32(exactly: number) else {
            throw invalid("\(what) must be a uint32")
        }
        return narrowed
    }

    static func describe(_ value: DagCborValue?) -> String {
        switch value {
        case .text(let text)?: text
        case nil: "undefined"
        default: "\(value!)"
        }
    }
}
