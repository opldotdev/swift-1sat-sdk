import Foundation

/// A MIME entity as BRC-169 envelope content carries it, parsed the way `@1sat/utils`
/// `parseMimeEntity` does: a header block, CRLF CRLF, then the body. Content with no header block
/// (or one that does not parse) is `text/plain`; a header block without `Content-Type` fails.
public struct MimeEntity: Equatable, Sendable {
    /// The `Content-Type` value as written, parameters included.
    public let contentType: String
    /// Header fields, names lowercased; empty when there was no header block.
    public let headers: [String: String]
    public let body: [UInt8]

    public static func parse(_ bytes: [UInt8]) throws -> MimeEntity {
        var end = -1
        var index = 0
        while index + 3 < bytes.count {
            if bytes[index] == 13, bytes[index + 1] == 10, bytes[index + 2] == 13, bytes[index + 3] == 10 {
                end = index
                break
            }
            index += 1
        }
        guard end >= 0, let headers = headerBlock(String(decoding: bytes[0..<end], as: UTF8.self)) else {
            return MimeEntity(contentType: "text/plain", headers: [:], body: bytes)
        }
        guard let contentType = headers["content-type"], !contentType.isEmpty else {
            throw MetanetError.delivery("MIME entity has no Content-Type")
        }
        return MimeEntity(contentType: contentType, headers: headers, body: Array(bytes[(end + 4)...]))
    }

    /// `^([!-9;-~]+):[ \t]*(.*)$` per line, with RFC 5322 folding of continuation lines.
    static func headerBlock(_ text: String) -> [String: String]? {
        var headers: [String: String] = [:]
        var last: String?
        for line in text.components(separatedBy: "\r\n") {
            if (line.hasPrefix(" ") || line.hasPrefix("\t")), let key = last {
                headers[key] = "\(headers[key] ?? "") \(jsTrim(line))"
                continue
            }
            let scalars = Array(line.unicodeScalars)
            guard let colon = scalars.firstIndex(of: ":"), colon > 0,
                  scalars[..<colon].allSatisfy({ (0x21...0x7e).contains($0.value) && $0 != ":" }) else {
                return nil
            }
            let rest = scalars[(colon + 1)...]
            // JavaScript's `.` does not match line terminators.
            guard !rest.contains(where: { [0x0a, 0x0d, 0x2028, 0x2029].contains($0.value) }) else { return nil }
            let key = String(String.UnicodeScalarView(scalars[..<colon])).lowercased()
            headers[key] = jsTrim(String(String.UnicodeScalarView(rest)))
            last = key
        }
        return headers
    }

    /// The media type of a `Content-Type` value: lowercased, parameters dropped.
    public static func mediaType(_ contentType: String) -> String {
        jsTrim(String(contentType.split(separator: ";", omittingEmptySubsequences: false).first ?? "")).lowercased()
    }

    static func jsTrim(_ text: String) -> String {
        var scalars = Substring(text).unicodeScalars
        let space: (Unicode.Scalar) -> Bool = {
            [0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x20, 0xa0, 0x1680, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff]
                .contains($0.value) || (0x2000...0x200a).contains($0.value)
        }
        while let first = scalars.first, space(first) { scalars.removeFirst() }
        while let last = scalars.last, space(last) { scalars.removeLast() }
        return String(scalars)
    }
}
