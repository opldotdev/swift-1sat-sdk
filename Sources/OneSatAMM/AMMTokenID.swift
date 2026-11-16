import OneSatColor

/// Token ids as Open Exchange reads and writes them: `lib/tokenId.ts` of `@dcasegr/amm-client`
/// 0.55.1 (skein-amm cc146be). A token id is written `<txid>_<vout>` (`_0` included); on input
/// `<txid>`, `<txid>_<vout>` and `<txid>.<vout>` name the same token (no vout is vout 0). The
/// parsed form is OneSatColor's `ColorAssetID`, whose `description` is that canonical text.
public enum AMMTokenID {
    /// `parseTokenId` (lib/tokenId.ts:43): any token id form, trimmed, hex in either case; nil
    /// for anything else.
    public static func parse(_ text: String) -> ColorAssetID? {
        parse(text, needVout: false)
    }

    /// `parseOutpoint` (lib/tokenId.ts:48): `<txid>.<vout>` or `<txid>_<vout>`; nil for anything
    /// else, a bare txid included.
    public static func parseOutpoint(_ text: String) -> ColorAssetID? {
        parse(text, needVout: true)
    }

    /// `sdkTokenId` (lib/tokenId.ts:115): any token id form as `<txid>_<vout>`. Throws for
    /// anything else, with the TS text.
    public static func canonical(_ text: String) throws -> String {
        guard let id = parse(text) else {
            throw OpenExchangeError.failed("not a token id (<txid>, <txid>_<vout> or <txid>.<vout>): \(text)")
        }
        return id.description
    }

    /// `parse` (lib/tokenId.ts:34): `^([0-9a-fA-F]{64})(?:[._](\d+))?$` on the trimmed text, the
    /// vout a safe integer no greater than 0xffffffff.
    static func parse(_ text: String, needVout: Bool) -> ColorAssetID? {
        let bytes = Array(jsTrim(text).utf8)
        guard bytes.count >= 64, bytes[..<64].allSatisfy(isHexDigit) else { return nil }
        let txid = String(decoding: bytes[..<64], as: UTF8.self).lowercased()
        let vout: UInt32
        if bytes.count == 64 {
            guard !needVout else { return nil }
            vout = 0
        } else {
            guard bytes[64] == UInt8(ascii: ".") || bytes[64] == UInt8(ascii: "_"),
                  let value = voutValue(bytes[65...]) else { return nil }
            vout = value
        }
        return try? ColorAssetID(txid: txid, vout: vout)
    }

    /// `\d+` as `Number` reads it: leading zeros allowed, at most 0xffffffff.
    private static func voutValue(_ digits: ArraySlice<UInt8>) -> UInt32? {
        guard !digits.isEmpty, digits.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
        let significant = digits.drop { $0 == 0x30 }
        guard significant.count <= 10 else { return nil }
        guard let value = UInt64(String(decoding: significant.isEmpty ? [0x30] : Array(significant), as: UTF8.self)),
              value <= UInt64(UInt32.max) else { return nil }
        return UInt32(value)
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
    }

    /// `String.prototype.trim`: JS whitespace and line terminators off both ends.
    static func jsTrim(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        guard let first = scalars.firstIndex(where: { !isJSWhitespace($0) }),
              let last = scalars.lastIndex(where: { !isJSWhitespace($0) }) else { return "" }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: scalars[first...last])
        return String(out)
    }

    static func isJSWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0d, 0x20, 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff: true
        default: false
        }
    }
}
