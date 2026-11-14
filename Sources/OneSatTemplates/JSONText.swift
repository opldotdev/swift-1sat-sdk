/// JSON string literals written exactly as JavaScript's `JSON.stringify` writes them, for JSON
/// that ends up in locking scripts or custom instructions and must match the TS bytes.
package enum JSONText {
    /// `JSON.stringify(text)` (ES2019 well-formed): `"` and `\` escaped, `\b \f \n \r \t` in their
    /// short forms, every other code point below U+0020 as lowercase `\u00xx`, and everything else,
    /// `/`, DEL, U+2028 and U+2029 included, as is.
    ///
    /// `JSON.stringify` also writes a lone surrogate as `\udxxx`. A Swift `String` cannot hold one
    /// (its scalars are always valid Unicode), so that case never reaches this function.
    package static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }
}
