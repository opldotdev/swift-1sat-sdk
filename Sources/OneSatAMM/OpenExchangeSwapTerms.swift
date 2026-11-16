import Foundation
import BSVKeys
import BSVCore
import ToolboxAuth
import OneSatTemplates

/// `SwapTerms` (market/relay.ts): the relay's terms for a swap on one token.
public struct OpenExchangeSwapTerms: Equatable, Sendable {
    /// Where the relay takes the commission: a hash160, lowercase hex; nil when it names none.
    public let commissionPkh: String?
    /// This market's minimum commission, basis points (0 when unset).
    public let minCommissionBps: Int

    public init(commissionPkh: String?, minCommissionBps: Int) {
        self.commissionPkh = commissionPkh
        self.minCommissionBps = minCommissionBps
    }
}

/// The app's `/call` route and `amm.swap.terms` (skein-amm cc146be web/ui/src/market/relay.ts,
/// the 0.55.1 client): `POST <base>/call`, JSON `{fn, args}`, BRC-104 signed, answered `{fn,
/// result}` (200) or `{fn, error: {code, message}}`. A read: nothing is built or sent but the
/// signed request.
extension OpenExchange {
    /// `SWAP_TERMS_FN`.
    public static let swapTermsFn = "amm.swap.terms"

    /// `swapTerms(signedFor(base), base)` for a token's instance (`base` its AMM base,
    /// `<origin>/@<tokenId>/amm`, where amm-p2p serves `amm.swap.terms`): the commission key the
    /// relay takes a swap's commission at, and the market's minimum commission. The request is
    /// signed (BRC-104) as `identity`, in a session with the token's instance.
    ///
    /// Throws `refused` for an error answer (its code, or `HTTP <status>`, and its message),
    /// `failed` for an answer that is not terms.
    public func swapTerms(tokenId: String, identity: PrivateKey) async throws -> OpenExchangeSwapTerms {
        do {
            let result = try await callApp(base: try tokenBase(tokenId), fn: Self.swapTermsFn, args: "{}", identity: identity)
            return try Self.parseSwapTerms(result)
        } catch {
            throw OpenExchangeError.of(error)
        }
    }

    /// `callApp`: one `{fn, args}` call on `<base>/call` (`args` its JSON text), the answer's
    /// `result`; a `refused` error for an error answer.
    func callApp(base: String, fn: String, args: String, identity: PrivateKey) async throws -> JSONValue {
        let callURL = "\(OpenExchangeURLs.trimTrailingSlashes(base))/call"
        let instance = OpenExchangeURLs.instanceBase(base)
        guard let instanceURL = URL(string: instance) else { throw OpenExchangeError.failed("Invalid URL: \(instance)") }
        let path = try WebURL(callURL).pathname
        let body = Array("{\"fn\":\(JSONText.quote(fn)),\"args\":\(args)}".utf8)
        let status: Int
        let answer: [UInt8]
        do {
            let response = try await session(identity, instanceURL).send(
                method: "POST", path: path, query: nil, headers: ["content-type": "application/json"], body: body
            )
            (status, answer) = (response.statusCode, response.body)
        } catch AuthTransportError.unauthenticatedReply(let replyStatus, let replyBody) {
            // An answer from in front of the instance's auth: its status and body, unsigned.
            (status, answer) = (replyStatus, replyBody)
        }
        let text = String(decoding: answer, as: UTF8.self)
        let value = JSONValue.parse(answer)
        if status == 200, let value {
            switch value {
            case .object(let members):
                if let result = members["result"] { return result }
            case .array, .null:
                break
            case .bool(false):
                break
            case .number(let n) where n == 0 || n.isNaN:
                break
            case .string(let s) where s.isEmpty:
                break
            default:
                // `"result" in answer` of a primitive JS would not search: a TypeError.
                throw OpenExchangeError.failed("TypeError: the answer is not an object: \(Self.preview(answer))")
            }
        }
        let error = value?["error"]
        let code = error?["code"]?.string
        let message = error?["message"]?.string ?? JS.prefix(text, 200)
        throw OpenExchangeError.refused(code: code, message: "\(code ?? "HTTP \(status)"): \(message)")
    }

    /// `parseSwapTerms`: `commissionPkh` 20 bytes (DAG-JSON bytes, hex or a byte array) or
    /// null / absent; `minCommissionBps` an integer 0 to 10000, absent 0.
    static func parseSwapTerms(_ x: JSONValue) throws -> OpenExchangeSwapTerms {
        let members: [String: JSONValue]
        switch x {
        case .object(let m): members = m
        case .array: members = [:]
        default: throw OpenExchangeError.failed("relay: not swap terms: \(jsonPrimitive(x))")
        }
        var min = 0
        if let m = members["minCommissionBps"], m != .null {
            guard case .number(let n) = m, n == n.rounded(.towardZero), n.isFinite, n >= 0, n <= 10_000 else {
                throw OpenExchangeError.failed("relay: minCommissionBps is not an integer, 0 to 10000")
            }
            min = Int(n)
        }
        switch members["commissionPkh"] {
        case nil, .null?:
            return OpenExchangeSwapTerms(commissionPkh: nil, minCommissionBps: min)
        case let raw?:
            guard let bytes = try readBytes(raw), bytes.count == 20 else {
                throw OpenExchangeError.failed("relay: commissionPkh is not 20 bytes")
            }
            return OpenExchangeSwapTerms(commissionPkh: Hex.encode(bytes), minCommissionBps: min)
        }
    }

    /// `readBytes` (market/relay.ts): DAG-JSON bytes (`{"/": {"bytes": <base64>}}`), hex or a
    /// byte array; nil for anything else.
    static func readBytes(_ x: JSONValue) throws -> [UInt8]? {
        switch x {
        case .array(let items):
            var out: [UInt8] = []
            for item in items {
                guard case .number(let n) = item, n == n.rounded(.towardZero), n >= 0, n < 256 else { return nil }
                out.append(UInt8(n))
            }
            return out
        case .string(let s):
            let bytes = Array(s.utf8)
            guard !bytes.isEmpty, bytes.count % 2 == 0, bytes.allSatisfy(isHexDigit) else { return nil }
            return try Hex.decode(s, maximumDecodedByteCount: bytes.count / 2)
        case .object:
            guard case .string(let b)? = x["/"]?["bytes"] else { return nil }
            let padded = b + String(repeating: "=", count: (4 - b.utf16.count % 4) % 4)
            return try base64ToArray(padded)
        default:
            return nil
        }
    }

    /// `Utils.toArray(text, "base64")` of `@bsv/sdk` 4.0.1: JS whitespace trimmed, `\r \n \t \f
    /// \v` and spaces dropped, URL-safe `-` `_` read as `+` `/`, one or two `=` only at the end;
    /// six bits per character, a partial last byte dropped.
    static func base64ToArray(_ text: String) throws -> [UInt8] {
        var units = Array(AMMTokenID.jsTrim(text).utf16).filter { ![0x0d, 0x0a, 0x09, 0x0c, 0x0b, 0x20].contains($0) }
        units = units.map { $0 == 0x2d ? 0x2b : ($0 == 0x5f ? 0x2f : $0) }
        if let pad = units.firstIndex(of: 0x3d) {
            let tail = units[pad...]
            guard (1...2).contains(tail.count), tail.allSatisfy({ $0 == 0x3d }) else {
                throw OpenExchangeError.failed("Invalid base64 padding")
            }
            units = Array(units[..<pad])
        }
        var out: [UInt8] = []
        var buffer = 0
        var bits = 0
        for (i, c) in units.enumerated() {
            let v: Int
            switch c {
            case 65...90: v = Int(c) - 65
            case 97...122: v = Int(c) - 97 + 26
            case 48...57: v = Int(c) - 48 + 52
            case 43: v = 62
            case 47: v = 63
            default: throw OpenExchangeError.failed("Invalid base64 character at index \(i)")
            }
            buffer = (buffer << 6) | v
            bits += 6
            while bits >= 8 {
                bits -= 8
                out.append(UInt8((buffer >> bits) & 0xff))
                buffer &= (1 << bits) - 1
            }
        }
        return out
    }

    /// `JSON.stringify(x)` of a JSON value that is not an object.
    static func jsonPrimitive(_ x: JSONValue) -> String {
        switch x {
        case .null: "null"
        case .bool(let b): b ? "true" : "false"
        case .number(let n): n.isFinite ? JS.string(n) : "null"
        case .string(let s): JSONText.quote(s)
        case .array, .object: "{}"
        }
    }

    private static func isHexDigit(_ b: UInt8) -> Bool {
        (0x30...0x39).contains(b) || (0x41...0x46).contains(b) || (0x61...0x66).contains(b)
    }
}
