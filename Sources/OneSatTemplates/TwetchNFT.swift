import Foundation
import BSVScript

/// A Twetch NFT ("twonk", such as the 456 Muties), minted on Twetch before 1Sat ordinals.
///
/// Matches `@1sat/wallet` `TwetchIndexer`. The locking script is
///
///     OP_HASH160 <20-byte hash> OP_EQUALVERIFY
///     OP_DUP OP_HASH160 <owner pkh> OP_EQUALVERIFY OP_CHECKSIG
///     OP_RETURN <JSON metadata>
///
/// Spending one needs the owner's signature and the hash preimage, so it is never plain funds.
/// Sending one is not supported.
public struct TwetchNFT: Equatable, Sendable {
    public struct Attribute: Equatable, Sendable {
        public let traitType: String
        public let value: String
        public let rarity: String?
    }

    /// The owner's public key hash (the P2PKH after the hash lock).
    public let ownerHash: [UInt8]
    /// The 20-byte hash the output is locked to.
    public let hashLock: [UInt8]
    public let title: String?
    public let description: String?
    /// `b://<txid>` reference to the image.
    public let image: String?
    public let number: Int?
    public let series: Int?
    public let rarity: String?
    public let rank: Int?
    /// `b://<txid>` reference to the 3D model (glTF).
    public let gltfModel: String?
    /// `b://<txid>` reference to the background image.
    public let background: String?
    public let attributes: [Attribute]

    /// `TWETCH_TAG`, the first wallet tag of every Twetch NFT output.
    public static let tag = "twetch"

    /// `TwetchIndexer` tags: `twetch`, then `name:<title>` when it has a title.
    public var tags: [String] {
        var tags = [Self.tag]
        if let title { tags.append("name:\(title)") }
        return tags
    }

    public static func decode(_ script: Script) -> TwetchNFT? {
        decode(bytes: script.bytes)
    }

    /// Nil unless the script has the Twetch NFT shape and its metadata is a JSON object with a
    /// title or an image.
    public static func decode(bytes s: [UInt8]) -> TwetchNFT? {
        // OP_HASH160 <20> OP_EQUALVERIFY, OP_DUP OP_HASH160 <20> OP_EQUALVERIFY OP_CHECKSIG,
        // OP_RETURN, then one push.
        guard s.count > 49,
              s[0] == 0xa9, s[1] == 0x14, s[22] == 0x88,
              s[23] == 0x76, s[24] == 0xa9, s[25] == 0x14, s[46] == 0x88, s[47] == 0xac,
              s[48] == 0x6a,
              let pushed = push(s, at: 49), !pushed.isEmpty,
              let json = try? JSONDecoder().decode(JSONItem.self, from: Data(pushed)),
              case .object(let fields) = json
        else { return nil }

        let title = fields["title"]?.text
        let image = fields["image"]?.text
        guard title != nil || image != nil else { return nil }

        var attributes: [Attribute] = []
        if case .array(let items)? = fields["attributes"] {
            for item in items {
                guard case .object(let trait) = item else { continue }
                let traitType = trait["trait_type"]?.text ?? ""
                let value = trait["value"]?.text ?? ""
                if traitType.isEmpty && value.isEmpty { continue }
                attributes.append(Attribute(traitType: traitType, value: value, rarity: trait["rarity"]?.text))
            }
        }

        return TwetchNFT(
            ownerHash: Array(s[26..<46]),
            hashLock: Array(s[2..<22]),
            title: title,
            description: fields["description"]?.text,
            image: image,
            number: fields["number"]?.integer,
            series: fields["series"]?.integer,
            rarity: fields["rarity"]?.text,
            rank: fields["rank"]?.integer,
            gltfModel: fields["gltfModel"]?.text,
            background: fields["background"]?.text,
            attributes: attributes
        )
    }

    /// The data of the push opcode at `offset`, or nil when it is not a complete push.
    static func push(_ s: [UInt8], at offset: Int) -> [UInt8]? {
        guard offset < s.count else { return nil }
        let op = Int(s[offset])
        var start = offset + 1
        let length: Int
        switch op {
        case 0x01...0x4b:
            length = op
        case 0x4c:
            guard start < s.count else { return nil }
            length = Int(s[start])
            start += 1
        case 0x4d:
            guard start + 2 <= s.count else { return nil }
            length = Int(s[start]) | Int(s[start + 1]) << 8
            start += 2
        case 0x4e:
            guard start + 4 <= s.count else { return nil }
            length = Int(s[start]) | Int(s[start + 1]) << 8 | Int(s[start + 2]) << 16 | Int(s[start + 3]) << 24
            start += 4
        default:
            return nil
        }
        guard start + length <= s.count else { return nil }
        return Array(s[start..<(start + length)])
    }
}

/// The JSON the metadata push holds, read as `TwetchIndexer` reads it.
private enum JSONItem: Decodable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONItem])
    case object([String: JSONItem])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONItem].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONItem].self)) }
    }

    /// `str`: a non-empty string, or a number as JavaScript's `String(n)` writes it.
    var text: String? {
        switch self {
        case .string(let value): return value.isEmpty ? nil : value
        case .number(let value):
            if value == value.rounded(), abs(value) < 1e21 { return String(format: "%.0f", value) }
            return "\(value)"
        default: return nil
        }
    }

    /// `int`: a number, or a decimal string, truncated toward zero.
    var integer: Int? {
        let value: Double?
        switch self {
        case .number(let number): value = number
        case .string(let string):
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            value = trimmed.isEmpty ? 0 : Double(trimmed)
        default: value = nil
        }
        guard let value, value.isFinite else { return nil }
        return Int(exactly: value.rounded(.towardZero))
    }
}
