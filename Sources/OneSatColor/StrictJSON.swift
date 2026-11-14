import Foundation
import OneSatTemplates

/// The JSON value model of the color module's strict parser (`strictJson.ts`): objects keep
/// their member order so a value can be written back exactly as `JSON.stringify` would.
public indirect enum StrictJSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([StrictJSON])
    case object([(String, StrictJSON)])

    public static func == (lhs: StrictJSON, rhs: StrictJSON) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): true
        case let (.bool(a), .bool(b)): a == b
        case let (.number(a), .number(b)): a == b
        case let (.string(a), .string(b)): a == b
        case let (.array(a), .array(b)): a == b
        case let (.object(a), .object(b)): a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: false
        }
    }

    public subscript(member: String) -> StrictJSON? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.0 == member }?.1
    }

    /// `JSON.stringify` output for this value. Numbers must be integers within 2^53 (the only
    /// numbers BRC-207 writes); anything else is a programming error and traps in debug.
    public var serialized: String {
        var out = ""
        write(into: &out)
        return out
    }

    private func write(into out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let value): out += value ? "true" : "false"
        case .number(let value):
            assert(value == value.rounded() && abs(value) <= 9_007_199_254_740_991)
            out += String(Int64(value))
        case .string(let value): Self.quote(value, into: &out)
        case .array(let items):
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                item.write(into: &out)
            }
            out += "]"
        case .object(let members):
            out += "{"
            for (i, (name, value)) in members.enumerated() {
                if i > 0 { out += "," }
                Self.quote(name, into: &out)
                out += ":"
                value.write(into: &out)
            }
            out += "}"
        }
    }

    /// `JSON.stringify` string quoting (`JSONText.quote`).
    static func quote(_ text: String, into out: inout String) {
        out += JSONText.quote(text)
    }

    // MARK: - Strict parsing

    static let maxDepth = 64

    /// Strict UTF-8 then strict JSON, as `parseStrictJsonBytes`: no BOM, no duplicate members,
    /// no unpaired surrogate escapes, no integers written as fractions or exponents, depth 64.
    public static func parse(bytes: [UInt8], label: String) throws -> StrictJSON {
        guard let text = ColorIdentifiers.strictUTF8(bytes) else { throw ColorError.invalid("\(label): not strict UTF-8") }
        return try parse(text, label: label)
    }

    public static func parse(_ text: String, label: String) throws -> StrictJSON {
        var parser = Parser(scalars: Array(text.unicodeScalars), label: label)
        let value = try parser.value(depth: 0)
        parser.whitespace()
        guard parser.position == parser.scalars.count else { throw parser.fail("trailing data") }
        return value
    }

    private struct Parser {
        let scalars: [Unicode.Scalar]
        let label: String
        var position = 0

        init(scalars: [Unicode.Scalar], label: String) { self.scalars = scalars; self.label = label }

        func fail(_ reason: String) -> ColorError { .invalid("\(label) is not strict JSON (\(reason))") }

        var current: Unicode.Scalar? { position < scalars.count ? scalars[position] : nil }

        mutating func whitespace() {
            while let c = current, c == " " || c == "\t" || c == "\n" || c == "\r" { position += 1 }
        }

        mutating func literal(_ word: String, _ value: StrictJSON) throws -> StrictJSON {
            let w = Array(word.unicodeScalars)
            guard position + w.count <= scalars.count, Array(scalars[position..<position + w.count]) == w else {
                throw fail("invalid literal")
            }
            position += w.count
            return value
        }

        mutating func value(depth: Int) throws -> StrictJSON {
            if depth > StrictJSON.maxDepth { throw fail("nesting too deep") }
            whitespace()
            switch current {
            case "{": return try object(depth: depth)
            case "[": return try array(depth: depth)
            case "\"": return .string(try string())
            case "t": return try literal("true", .bool(true))
            case "f": return try literal("false", .bool(false))
            case "n": return try literal("null", .null)
            default: return try number()
            }
        }

        private func isDigit(_ c: Unicode.Scalar?) -> Bool { c.map { ("0"..."9").contains($0) } ?? false }

        /// `-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?`, sticky.
        mutating func number() throws -> StrictJSON {
            let start = position
            var p = position
            func at(_ i: Int) -> Unicode.Scalar? { i < scalars.count ? scalars[i] : nil }
            if at(p) == "-" { p += 1 }
            if at(p) == "0" { p += 1 }
            else if let c = at(p), ("1"..."9").contains(c) { p += 1; while isDigit(at(p)) { p += 1 } }
            else { throw fail("invalid value") }
            var fractionOrExponent = false
            if at(p) == ".", isDigit(at(p + 1)) { p += 2; while isDigit(at(p)) { p += 1 }; fractionOrExponent = true }
            if at(p) == "e" || at(p) == "E" {
                var q = p + 1
                if at(q) == "+" || at(q) == "-" { q += 1 }
                if isDigit(at(q)) { q += 1; while isDigit(at(q)) { q += 1 }; p = q; fractionOrExponent = true }
            }
            let text = String(String.UnicodeScalarView(scalars[start..<p]))
            guard let value = Double(text) else { throw fail("invalid value") }
            position = p
            if fractionOrExponent, value == value.rounded(), abs(value) < 1e21 {
                throw fail("an integer written as a fraction or exponent")
            }
            return .number(value)
        }

        mutating func hex4() throws -> UInt32 {
            guard position + 4 <= scalars.count else { throw fail("invalid unicode escape") }
            var value: UInt32 = 0
            for scalar in scalars[position..<position + 4] {
                guard let digit = Int(String(scalar), radix: 16) else { throw fail("invalid unicode escape") }
                value = value * 16 + UInt32(digit)
            }
            position += 4
            return value
        }

        mutating func string() throws -> String {
            position += 1
            var result = String.UnicodeScalarView()
            while true {
                guard let c = current else { throw fail("unterminated string") }
                position += 1
                if c == "\"" { return String(result) }
                if c.value < 0x20 { throw fail("control character in string") }
                if c == "\\" { result.append(try escape()) } else { result.append(c) }
            }
        }

        mutating func escape() throws -> Unicode.Scalar {
            guard let e = current else { throw fail("invalid escape") }
            position += 1
            switch e {
            case "\"": return "\""
            case "\\": return "\\"
            case "/": return "/"
            case "b": return "\u{08}"
            case "f": return "\u{0C}"
            case "n": return "\n"
            case "r": return "\r"
            case "t": return "\t"
            case "u": break
            default: throw fail("invalid escape")
            }
            let unit = try hex4()
            if (0xdc00...0xdfff).contains(unit) { throw fail("unpaired surrogate") }
            if !(0xd800...0xdbff).contains(unit) {
                guard let scalar = Unicode.Scalar(unit) else { throw fail("invalid unicode escape") }
                return scalar
            }
            guard position + 2 <= scalars.count, scalars[position] == "\\", scalars[position + 1] == "u" else {
                throw fail("unpaired surrogate")
            }
            position += 2
            let low = try hex4()
            guard (0xdc00...0xdfff).contains(low),
                  let scalar = Unicode.Scalar(0x10000 + ((unit - 0xd800) << 10) + (low - 0xdc00)) else {
                throw fail("unpaired surrogate")
            }
            return scalar
        }

        mutating func array(depth: Int) throws -> StrictJSON {
            position += 1
            var items: [StrictJSON] = []
            whitespace()
            if current == "]" { position += 1; return .array(items) }
            while true {
                items.append(try value(depth: depth + 1))
                whitespace()
                let next = current
                position += 1
                if next == "]" { return .array(items) }
                if next != "," { throw fail("expected , or ]") }
            }
        }

        mutating func object(depth: Int) throws -> StrictJSON {
            position += 1
            var members: [(String, StrictJSON)] = []
            var names = Set<String>()
            whitespace()
            if current == "}" { position += 1; return .object(members) }
            while true {
                whitespace()
                guard current == "\"" else { throw fail("expected member name") }
                let name = try string()
                // JS object keys compare by UTF-16 code units; Swift `String` equality is
                // canonical equivalence, so compare the scalars.
                let key = name.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: ",")
                guard names.insert(key).inserted else { throw fail("duplicate member \(name)") }
                whitespace()
                let colon = current
                position += 1
                guard colon == ":" else { throw fail("expected :") }
                members.append((name, try value(depth: depth + 1)))
                whitespace()
                let next = current
                position += 1
                if next == "}" { return .object(members) }
                if next != "," { throw fail("expected , or }") }
            }
        }
    }

    // MARK: - Shape helpers (strictJson.ts)

    func object(_ label: String) throws -> [(String, StrictJSON)] {
        guard case .object(let members) = self else { throw ColorError.invalid("\(label) must be a JSON object") }
        return members
    }

    func array(_ label: String) throws -> [StrictJSON] {
        guard case .array(let items) = self else { throw ColorError.invalid("\(label) must be an array") }
        return items
    }

    func uint32(_ label: String) throws -> UInt32 {
        guard case .number(let value) = self, value == value.rounded(), value >= 0, value <= Double(UInt32.max) else {
            throw ColorError.invalid("\(label) must be an integer in 0..2^32-1")
        }
        return UInt32(value)
    }

    func string(_ label: String) throws -> String {
        guard case .string(let value) = self else { throw ColorError.invalid("\(label) must be a string") }
        return value
    }

    /// Requires every named member, allows the optional ones, refuses anything else.
    static func exactMembers(_ members: [(String, StrictJSON)], required: [String], optional: [String] = [], label: String) throws {
        let names = members.map(\.0)
        for name in required where !names.contains(name) { throw ColorError.invalid("\(label) is missing \(name)") }
        for name in names where !required.contains(name) && !optional.contains(name) {
            throw ColorError.invalid("\(label) has unknown member \(name)")
        }
    }
}

extension Array where Element == (String, StrictJSON) {
    subscript(member name: String) -> StrictJSON? { first { $0.0 == name }?.1 }
}
