import BSVCore
import OneSatCBOR

/// Field codecs for key/value PushDrop fields (`key, value, …, signature`).
///
/// Port of `packages/utils/src/fields.ts` plus the OpNS field constants from
/// `packages/types/src/constants.ts`. Each key names its value's encoding: `identity` is a raw
/// 33-byte compressed public key, `profile` is a DAG-CBOR map. The OpNS publish
/// (``OpNS/register(_:_:)``) is one user; this type only encodes and decodes single values and
/// splits a field list into pairs.
public enum OpnsFields {
    /// `IDENTITY_FIELD`. Value: 33-byte compressed identity public key (raw bytes).
    public static let identityField = "identity"
    /// `PROFILE_FIELD`. Value: DAG-CBOR map, see ``ProfileKey``.
    public static let profileField = "profile"

    /// `PROFILE_FIELDS`: member names inside the `profile` map. PROVISIONAL in the TS
    /// (b-open-io/1sat-sdk issue #83); change them here, nowhere else.
    public enum ProfileKey {
        public static let domain = "domain"
        public static let name = "name"
        public static let avatar = "avatar"
    }

    /// Value of the `profile` field. Optional members are absent from the map when unset.
    public struct Profile: Equatable, Sendable {
        /// BRC-169 ecosystem domain, as entered. Required, non-empty.
        public var domain: String
        /// Presentation name.
        public var name: String?
        /// 36-byte outpoint (txid internal order ‖ vout LE) of an image ordinal.
        public var avatar: [UInt8]?

        public init(domain: String, name: String? = nil, avatar: [UInt8]? = nil) {
            self.domain = domain
            self.name = name
            self.avatar = avatar
        }
    }

    /// `isIdentityKey`: 33 bytes, `02`/`03` prefix.
    public static func isIdentityKey(_ bytes: [UInt8]) -> Bool {
        bytes.count == 33 && (bytes[0] == 0x02 || bytes[0] == 0x03)
    }

    /// `encodeProfile`: values are written exactly as given (no trimming, case folding or
    /// format checks). An unset or empty `name` / `avatar` is omitted.
    public static func encodeProfile(_ profile: Profile) throws -> [UInt8] {
        guard !profile.domain.isEmpty else { throw OpnsFieldError.profileDomainRequired }
        var entries: [(key: String, value: DagCborValue)] = [
            (ProfileKey.domain, .text(profile.domain)),
        ]
        if let name = profile.name, !name.isEmpty {
            entries.append((ProfileKey.name, .text(name)))
        }
        if let avatar = profile.avatar, !avatar.isEmpty {
            guard avatar.count == 36 else { throw OpnsFieldError.profileAvatarNotOutpoint }
            entries.append((ProfileKey.avatar, .bytes(avatar)))
        }
        return try DagCbor.encode(.map(DagCborMap(entries)))
    }

    /// `decodeProfile`: decode and validate. Unknown map members are ignored.
    ///
    /// Mirrors the JS checks on the decoded value: a byte string or CID is a JS object, so it
    /// fails as "missing domain"; every other non-map is "not a map". DAG-CBOR errors throw
    /// ``DagCborError``.
    public static func decodeProfile(_ bytes: [UInt8]) throws -> Profile {
        let map: DagCborMap
        switch try DagCbor.decode(bytes) {
        case .map(let value):
            map = value
        case .bytes, .link:
            throw OpnsFieldError.profileMissingDomain
        default:
            throw OpnsFieldError.profileNotAMap
        }
        guard case .text(let domain)? = map[ProfileKey.domain], !domain.isEmpty else {
            throw OpnsFieldError.profileMissingDomain
        }
        var profile = Profile(domain: domain)
        if let name = map[ProfileKey.name] {
            guard case .text(let text) = name else { throw OpnsFieldError.profileNameNotString }
            profile.name = text
        }
        if let avatar = map[ProfileKey.avatar] {
            guard case .bytes(let raw) = avatar, raw.count == 36 else {
                throw OpnsFieldError.profileAvatarNot36Bytes
            }
            profile.avatar = raw
        }
        return profile
    }

    /// `fieldPairs`: split fields (signature already removed) into `(key, value)` pairs, keys
    /// decoded as UTF-8 (invalid bytes become U+FFFD, as `Utils.toUTF8` does).
    public static func fieldPairs(_ fields: [[UInt8]]) throws -> [(key: String, value: [UInt8])] {
        guard fields.count % 2 == 0 else { throw OpnsFieldError.fieldsNotPairs }
        return stride(from: 0, to: fields.count, by: 2).map {
            (String(decoding: fields[$0], as: UTF8.self), fields[$0 + 1])
        }
    }

    /// `assertPublishFields` from `apply/opnsRegister.ts`: exactly one `identity` (33-byte
    /// compressed key), at most one `profile` (valid profile). Unknown keys are allowed.
    public static func assertPublishFields(_ fields: [[UInt8]]) throws {
        var identities = 0
        var profiles = 0
        for (key, value) in try fieldPairs(fields) {
            if key == identityField {
                guard isIdentityKey(value) else { throw OpnsFieldError.identityNotCompressedKey }
                identities += 1
            } else if key == profileField {
                _ = try decodeProfile(value)
                profiles += 1
            }
        }
        guard identities == 1, profiles <= 1 else { throw OpnsFieldError.publishFieldCount }
    }

    /// `parseOutpoint` + `outpointToWire`: `txid.vout` or `txid_vout` to 36 bytes (txid in
    /// internal order, vout little-endian).
    public static func outpointWire(_ outpoint: String) throws -> [UInt8] {
        let utf8 = Array(outpoint.utf8)
        guard utf8.count >= 66, utf8[64] == UInt8(ascii: ".") || utf8[64] == UInt8(ascii: "_")
        else {
            throw OpnsFieldError.invalidOutpoint(outpoint)
        }
        let voutText = String(decoding: utf8[65...], as: UTF8.self)
        guard let txid = try? Hex.decode(
                  String(decoding: utf8[0..<64], as: UTF8.self),
                  maximumDecodedByteCount: 32
              ),
              txid.count == 32,
              voutText.utf8.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }),
              let vout = UInt32(voutText)
        else {
            throw OpnsFieldError.invalidOutpoint(outpoint)
        }
        return txid.reversed() + [
            UInt8(vout & 0xff),
            UInt8((vout >> 8) & 0xff),
            UInt8((vout >> 16) & 0xff),
            UInt8(vout >> 24),
        ]
    }
}

/// Field-codec failures. `wireMessage` is the TS `Error.message`.
public enum OpnsFieldError: Error, Equatable, Sendable {
    case profileDomainRequired
    case profileAvatarNotOutpoint
    case profileNotAMap
    case profileMissingDomain
    case profileNameNotString
    case profileAvatarNot36Bytes
    case fieldsNotPairs
    case identityNotCompressedKey
    case publishFieldCount
    case invalidOutpoint(String)

    public var wireMessage: String {
        switch self {
        case .profileDomainRequired:
            return "profile domain is required"
        case .profileAvatarNotOutpoint:
            return "profile avatar must be a 36-byte outpoint"
        case .profileNotAMap:
            return "profile is not a map"
        case .profileMissingDomain:
            return "profile: missing domain"
        case .profileNameNotString:
            return "profile: name is not a string"
        case .profileAvatarNot36Bytes:
            return "profile: avatar is not 36 bytes"
        case .fieldsNotPairs:
            return "fields are not key/value pairs"
        case .identityNotCompressedKey:
            return "opns.register apply: identity is not a compressed key"
        case .publishFieldCount:
            return "opns.register apply: fields need exactly one identity and at most one profile"
        case .invalidOutpoint(let outpoint):
            return "Invalid outpoint format: \(outpoint)"
        }
    }
}
