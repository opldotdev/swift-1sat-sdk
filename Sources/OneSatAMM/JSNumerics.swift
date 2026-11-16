import Foundation
import BigInt

/// JavaScript's numeric conversions where the TS client and engine lean on them, so a Swift
/// result is the one TS computes: `Number(bigint)`, `BigInt(x)`, `Number(x)`, `String(number)`,
/// `Math.round` and `10 ** n`.
enum JS {
    /// `BigInt(x)` threw: a `RangeError` (a number that is not an integer) or a `SyntaxError` (a
    /// string that is not an integer literal), or a `TypeError` (null).
    struct ConversionError: Error, Equatable, Sendable, CustomStringConvertible {
        let description: String
    }

    // MARK: - Number(bigint)

    /// `Number(b)`: the nearest double, ties to even; ±Infinity past the largest finite.
    static func number(_ b: BigInt) -> Double {
        let magnitude = b.magnitude
        let width = magnitude.bitWidth
        let value: Double
        if width <= 53 {
            value = Double(UInt64(magnitude))
        } else {
            var shift = width - 53
            var top = magnitude >> shift
            let rest = magnitude - (top << shift)
            let half = BigUInt(1) << (shift - 1)
            if rest > half || (rest == half && top & 1 == 1) {
                top += 1
                if top.bitWidth > 53 {
                    top >>= 1
                    shift += 1
                }
            }
            value = Double(sign: .plus, exponent: shift, significand: Double(UInt64(top)))
        }
        return b.sign == .minus ? -value : value
    }

    // MARK: - BigInt(x)

    /// `BigInt(n)` of a number: its exact value; a `RangeError` for anything not an integer.
    static func bigInt(_ n: Double) throws -> BigInt {
        guard n.isFinite, n == n.rounded(.towardZero), let value = BigInt(exactly: n) else {
            throw ConversionError(description: "RangeError: The number \(string(n)) cannot be converted to a BigInt because it is not an integer")
        }
        return value
    }

    /// `BigInt(s)` of a string (StringToBigInt): JS whitespace trimmed; empty is 0; a decimal
    /// integer with an optional sign, or `0x`/`0o`/`0b` digits with no sign; anything else a
    /// `SyntaxError`.
    static func bigInt(_ text: String) throws -> BigInt {
        let s = AMMTokenID.jsTrim(text)
        if s.isEmpty { return 0 }
        let bytes = Array(s.utf8)
        let fail = ConversionError(description: "SyntaxError: Cannot convert \(text) to a BigInt")
        if bytes.count > 2, bytes[0] == UInt8(ascii: "0") {
            let radix: Int? = switch bytes[1] {
            case UInt8(ascii: "x"), UInt8(ascii: "X"): 16
            case UInt8(ascii: "o"), UInt8(ascii: "O"): 8
            case UInt8(ascii: "b"), UInt8(ascii: "B"): 2
            default: nil
            }
            if let radix {
                let digits = String(decoding: bytes[2...], as: UTF8.self)
                guard digits.utf8.allSatisfy({ digitValue($0).map { $0 < radix } ?? false }),
                      let value = BigInt(digits, radix: radix) else { throw fail }
                return value
            }
        }
        var digits = bytes[...]
        var negative = false
        if let first = digits.first, first == UInt8(ascii: "+") || first == UInt8(ascii: "-") {
            negative = first == UInt8(ascii: "-")
            digits = digits.dropFirst()
        }
        guard !digits.isEmpty, digits.allSatisfy({ (0x30...0x39).contains($0) }),
              let value = BigInt(String(decoding: digits, as: UTF8.self)) else { throw fail }
        return negative ? -value : value
    }

    /// `BigInt(v)` of a parsed JSON value, as JS converts it: a number or string as above, a
    /// boolean 0 or 1, an array by its `String(...)` (`[]` is 0, `["5"]` is 5); null and objects
    /// throw.
    static func bigInt(_ value: JSONValue) throws -> BigInt {
        switch value {
        case .number(let n): return try bigInt(n)
        case .string(let s): return try bigInt(s)
        case .bool(let b): return b ? 1 : 0
        case .array: return try bigInt(string(value))
        case .null: throw ConversionError(description: "TypeError: Cannot convert null to a BigInt")
        case .object: throw ConversionError(description: "SyntaxError: Cannot convert [object Object] to a BigInt")
        }
    }

    // MARK: - Number(x)

    /// `Number(v)` of a parsed JSON value (ToNumber): null 0, a boolean 0 or 1, a string by
    /// StringToNumber, an array by its `String(...)`, an object NaN.
    static func number(_ value: JSONValue) -> Double {
        switch value {
        case .null: return 0
        case .bool(let b): return b ? 1 : 0
        case .number(let n): return n
        case .string(let s): return number(s)
        case .array: return number(string(value))
        case .object: return .nan
        }
    }

    /// StringToNumber: JS whitespace trimmed; empty is 0; `Infinity` with a sign; `0x`/`0o`/`0b`
    /// digits; a decimal literal (digits, a point, an exponent); anything else NaN.
    static func number(_ text: String) -> Double {
        let s = AMMTokenID.jsTrim(text)
        if s.isEmpty { return 0 }
        switch s {
        case "Infinity", "+Infinity": return .infinity
        case "-Infinity": return -.infinity
        default: break
        }
        let bytes = Array(s.utf8)
        if bytes.count > 2, bytes[0] == UInt8(ascii: "0") {
            let radix: Int? = switch bytes[1] {
            case UInt8(ascii: "x"), UInt8(ascii: "X"): 16
            case UInt8(ascii: "o"), UInt8(ascii: "O"): 8
            case UInt8(ascii: "b"), UInt8(ascii: "B"): 2
            default: nil
            }
            if let radix {
                let digits = String(decoding: bytes[2...], as: UTF8.self)
                guard digits.utf8.allSatisfy({ digitValue($0).map { $0 < radix } ?? false }),
                      let value = BigInt(digits, radix: radix) else { return .nan }
                return number(value)
            }
        }
        guard isDecimalLiteral(bytes), let value = Double(s) else { return .nan }
        return value
    }

    /// `[+-]? (digits (. digits?)? | . digits) ([eE] [+-]? digits)?`.
    private static func isDecimalLiteral(_ bytes: [UInt8]) -> Bool {
        var i = 0
        func digits() -> Int {
            let start = i
            while i < bytes.count, (0x30...0x39).contains(bytes[i]) { i += 1 }
            return i - start
        }
        if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
        var mantissa = digits()
        if i < bytes.count, bytes[i] == UInt8(ascii: ".") {
            i += 1
            mantissa += digits()
        }
        guard mantissa > 0 else { return false }
        if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
            i += 1
            if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
            guard digits() > 0 else { return false }
        }
        return i == bytes.count
    }

    private static func digitValue(_ byte: UInt8) -> Int? {
        switch byte {
        case 0x30...0x39: Int(byte - 0x30)
        case 0x41...0x46: Int(byte - 0x41 + 10)
        case 0x61...0x66: Int(byte - 0x61 + 10)
        default: nil
        }
    }

    // MARK: - String(x)

    /// `String(v)` of a parsed JSON value, as an array's elements join (null and empty as "").
    static func string(_ value: JSONValue) -> String {
        switch value {
        case .null: "null"
        case .bool(let b): b ? "true" : "false"
        case .number(let n): string(n)
        case .string(let s): s
        case .array(let items):
            items.map { item -> String in
                if case .null = item { return "" }
                return string(item)
            }.joined(separator: ",")
        case .object: "[object Object]"
        }
    }

    /// `String(n)` (Number::toString): the shortest digits that round-trip (as Swift's own
    /// description picks them), written as ECMAScript writes them.
    static func string(_ n: Double) -> String {
        if n.isNaN { return "NaN" }
        if n == 0 { return "0" }
        if n.isInfinite { return n < 0 ? "-Infinity" : "Infinity" }
        if n < 0 { return "-" + string(-n) }
        // Swift's shortest round-trip form: "d.ddd", "d.ddde±x", "ddd.0" or "0.000ddd".
        let text = "\(n)"
        var mantissa = text
        var exponent = 0
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = String(text[..<e])
            exponent = Int(text[text.index(after: e)...]) ?? 0
        }
        let parts = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        let whole = String(parts[0])
        let fraction = parts.count > 1 ? String(parts[1]) : ""
        // digits × 10^(point - digits.count), with `digits` the significant digits.
        var digits = whole + fraction
        var point = whole.count + exponent
        while digits.hasPrefix("0") && digits.count > 1 {
            digits.removeFirst()
            point -= 1
        }
        while digits.hasSuffix("0") && digits.count > 1 { digits.removeLast() }
        let k = digits.count
        let ndigits = point
        if k <= ndigits && ndigits <= 21 {
            return digits + String(repeating: "0", count: ndigits - k)
        }
        if 0 < ndigits && ndigits <= 21 {
            let index = digits.index(digits.startIndex, offsetBy: ndigits)
            return digits[..<index] + "." + digits[index...]
        }
        if -6 < ndigits && ndigits <= 0 {
            return "0." + String(repeating: "0", count: -ndigits) + digits
        }
        let e = ndigits - 1
        let sign = e < 0 ? "-" : "+"
        let head = String(digits.prefix(1))
        let tail = digits.dropFirst()
        return head + (tail.isEmpty ? "" : "." + tail) + "e" + sign + String(abs(e))
    }

    // MARK: - Math

    /// `Math.round(x)`: the nearest integer, a half toward +∞.
    static func round(_ x: Double) -> Double {
        guard x.isFinite else { return x }
        let down = x.rounded(.down)
        return x - down >= 0.5 ? down + 1 : down
    }

    /// `10 ** n`: exact for 0 through 22, as every power of ten there is a double.
    static func pow10(_ n: Int) -> Double {
        if (0...22).contains(n) { return exactPowersOfTen[n] }
        return Foundation.pow(10, Double(n))
    }

    private static let exactPowersOfTen: [Double] = [
        1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11,
        1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22,
    ]

    // MARK: - Strings

    /// `a < b` on JS strings: UTF-16 code units, lexicographically.
    static func less(_ a: String, _ b: String) -> Bool {
        a.utf16.lexicographicallyPrecedes(b.utf16)
    }

    /// `text.slice(0, n)`: the first `n` UTF-16 code units.
    static func prefix(_ text: String, _ n: Int) -> String {
        let units = Array(text.utf16.prefix(n))
        return String(decoding: units, as: UTF16.self)
    }
}
