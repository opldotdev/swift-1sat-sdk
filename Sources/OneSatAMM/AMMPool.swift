import BigInt
import BSVScript
import OneSatTemplates

/// `PoolArgs` (pool/template.ts): the readonly constructor arguments compiled into the code.
public struct AMMPoolArgs: Equatable, Sendable {
    /// The token's 32-byte BRC-162 id, hex, wire (internal) byte order.
    public let assetId: String
    public let lpFeeBps: BigInt
    public let validatorFeeBps: BigInt
    /// The relay's commission, bps of amountIn in the input asset.
    public let commissionBps: BigInt
}

/// `PoolFields` (pool/template.ts): the state after OP_RETURN; keys 33-byte compressed hex.
public struct AMMPoolFields: Equatable, Sendable {
    public let tokenReserve: BigInt
    public let lpPubKey: String
    /// 33 zero bytes (hex) once rescinded.
    public let validatorPubKey: String
    public let validatorIdentity: String
    /// The validator's nonce, 32 bytes hex.
    public let nonce: String
    /// Where a sats-in Swap pays the LP fee, 20 bytes hex.
    public let lpSatsPkh: String
    /// Where a token-in Swap pays the LP fee, 20 bytes hex.
    public let lpTokenPkh: String
    /// The validator's affirmation, DER hex ("" when the pool carries none).
    public let affirmation: String
}

/// `Pool` (pool/template.ts): a decoded pool locking script.
public struct AMMPool: Equatable, Sendable {
    /// The layout: 3, the only one (0.55.0).
    public let version: Int
    public let args: AMMPoolArgs
    public let state: AMMPoolFields
    /// The Rúnar code, hex: what a call pushes as `_codePart`.
    public let code: String
    /// `code || OP_RETURN || state`, hex.
    public let contractScript: String

    /// `RESCINDED_KEY`: a cleared ValidatorPubKey, 33 zero bytes.
    public static let rescindedKey = String(repeating: "00", count: 33)

    /// `PoolTemplate.decode`: a pool output's locking script, a 1Color value prefix with a
    /// 32-byte id and no payload, then the Pool artifact (its template between the constructor
    /// slots), then the state; the prefix's id the AssetId and its amount the TokenReserve. Nil
    /// for anything else, a layout-1 or layout-2 pool included.
    public static func decode(_ script: [UInt8]) -> AMMPool? {
        guard let prefix = decodeOneColor(script), prefix.role == .value, prefix.idBytes?.count == 32 else { return nil }

        let contract = Array(script[prefix.length...])
        let contractScript = hex(contract)
        guard Runar.matchesArtifact(Runar.pool, contract) else { return nil }
        let ctor = Runar.extractConstructorArgs(Runar.pool, contract)
        guard let raw = try? Runar.extractStateFromScript(Runar.pool, contract) else { return nil }

        guard case .data(let assetId)? = ctor["assetId"], isHex(assetId, 32),
              case .number(let lpFeeBps)? = ctor["lpFeeBps"],
              case .number(let validatorFeeBps)? = ctor["validatorFeeBps"],
              case .number(let commissionBps)? = ctor["commissionBps"] else { return nil }
        guard case .number(let tokenReserve)? = raw["tokenReserve"],
              case .data(let lpPubKey)? = raw["lpPubKey"], isHex(lpPubKey, 33),
              case .data(let validatorPubKey)? = raw["validatorPubKey"], isHex(validatorPubKey, 33),
              case .data(let validatorIdentity)? = raw["validatorIdentity"], isHex(validatorIdentity, 33) else { return nil }
        guard case .data(let nonce)? = raw["nonce"], isHex(nonce, 32),
              case .data(let lpSatsPkh)? = raw["lpSatsPkh"], isHex(lpSatsPkh, 20),
              case .data(let lpTokenPkh)? = raw["lpTokenPkh"], isHex(lpTokenPkh, 20),
              case .data(let affirmation)? = raw["affirmation"] else { return nil }
        if prefix.payload != nil { return nil } // a pool writes no payload
        guard let idBytes = prefix.idBytes, assetId == hex(idBytes), tokenReserve == BigInt(prefix.amount) else { return nil }

        let opReturn = Runar.findLastOpReturn(contract)
        return AMMPool(
            version: 3,
            args: AMMPoolArgs(assetId: assetId, lpFeeBps: lpFeeBps, validatorFeeBps: validatorFeeBps, commissionBps: commissionBps),
            state: AMMPoolFields(
                tokenReserve: tokenReserve, lpPubKey: lpPubKey, validatorPubKey: validatorPubKey,
                validatorIdentity: validatorIdentity, nonce: nonce, lpSatsPkh: lpSatsPkh, lpTokenPkh: lpTokenPkh,
                affirmation: affirmation
            ),
            code: hex(Array(contract[..<Swift.max(opReturn, 0)])),
            contractScript: contractScript
        )
    }

    /// `PoolTemplate.decode` of a `Script`.
    public static func decode(_ script: Script) -> AMMPool? {
        decode(script.bytes)
    }

    /// `PoolTemplate.rescinded`: the validator rescinded the pool (ValidatorPubKey 33 zero bytes).
    public var rescinded: Bool { state.validatorPubKey == Self.rescindedKey }

    // MARK: - The 1Color prefix (pool/oneColor.ts)

    /// `OneColorPrefix` (pool/oneColor.ts).
    struct OneColorPrefix: Equatable {
        let role: OneColorRole
        let idBytes: [UInt8]?
        let amount: UInt64
        let payload: [UInt8]?
        /// Where the inner lock starts.
        let length: Int
    }

    /// `decodeOneColor` (pool/oneColor.ts): the 1Color prefix at the start of `script`
    /// (`OneColor.decode`), or nil when it has none.
    static func decodeOneColor(_ script: [UInt8]) -> OneColorPrefix? {
        guard let parsed = try? Script(bytes: script, maximumByteCount: script.count),
              let token = OneColor.decode(parsed) else { return nil }
        return OneColorPrefix(
            role: token.role, idBytes: token.idBytes, amount: token.amount, payload: token.payload,
            length: script.count - token.lock.bytes.count
        )
    }

    static func hex(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count * 2)
        for byte in bytes { out += [digits[Int(byte >> 4)], digits[Int(byte & 0x0f)]] }
        return String(decoding: out, as: UTF8.self)
    }

    /// `isHex(s, n)`: exactly `n` bytes of lowercase hex.
    static func isHex(_ text: String, _ bytes: Int) -> Bool {
        text.utf8.count == bytes * 2 && text.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }
}

/// The pieces of runar-sdk (vendored in skein-amm web/ui/src/vendor/runar, runar-v1.0.0-rc.1)
/// that decoding a pool reads: `matchesArtifact`, `extractConstructorArgs`, `findLastOpReturn`
/// (script-utils.ts, state.ts) and `extractStateFromScript` / `deserializeState`. Over bytes, not
/// hex: every offset is a byte offset, as the hex's are twice over.
enum Runar {
    struct Artifact: Sendable {
        let script: [UInt8]
        let constructorSlots: [(byteOffset: Int, paramIndex: Int)]
        let constructorParams: [(name: String, type: String)]
        let stateFields: [(name: String, type: String)]
    }

    /// A decoded argument or state field: a number, a boolean or bytes (hex).
    enum Value: Equatable, Sendable {
        case number(BigInt)
        case bool(Bool)
        case data(String)
    }

    struct StateError: Error {}

    /// `poolArtifact` (pool/artifact.ts): the artifact with its code-separator slots resolved,
    /// each `00` at byte 1's index written `OP_1` (`resolveCodeSepSlots`).
    static let pool: Artifact = {
        var script = hexBytes(PoolArtifact.templateHex)
        for slot in PoolArtifact.codeSepIndexSlots {
            precondition(slot.codeSepIndex == 1 && script[slot.byteOffset] == 0x00, "pool artifact: a codeSepIndex slot not at byte 1")
            script[slot.byteOffset] = 0x51
        }
        return Artifact(
            script: script, constructorSlots: PoolArtifact.constructorSlots,
            constructorParams: PoolArtifact.constructorParams, stateFields: PoolArtifact.stateFields
        )
    }()

    /// `STATE_FIELD_WIDTHS` (runar-ir-schema state-layout.ts).
    static func stateWidth(_ type: String) -> (size: Int, encoding: String)? {
        switch type {
        case "int", "bigint": (8, "num2bin-le8")
        case "bool", "boolean": (1, "bool1")
        case "PubKey": (33, "raw")
        case "Addr", "Ripemd160": (20, "raw")
        case "Sha256": (32, "raw")
        case "Point", "P256Point": (64, "raw")
        case "P384Point": (96, "raw")
        default: nil
        }
    }

    /// `abiValueEncoding` (runar-ir-schema abi-type-encoding.ts).
    static func abiEncoding(_ type: String) -> String {
        switch type {
        case "bigint", "int", "RabinSig", "RabinPubKey": "scriptnum"
        case "boolean", "bool": "bool"
        default: "data"
        }
    }

    // MARK: - script-utils.ts

    /// `readScriptElement`: the element at `offset`; nil where its length bytes or data run past
    /// the end (TS reads NaN and short slices there, and no match follows for this artifact,
    /// whose template goes on past its last slot).
    static func readScriptElement(_ s: [UInt8], _ offset: Int) -> (data: [UInt8], total: Int, opcode: Int)? {
        guard offset < s.count else { return nil }
        let opcode = Int(s[offset])
        var header = 1
        let length: Int
        switch opcode {
        case 0x00: return ([], 1, opcode)
        case 0x01...0x4b: length = opcode
        case 0x4c:
            guard offset + 2 <= s.count else { return nil }
            length = Int(s[offset + 1])
            header = 2
        case 0x4d:
            guard offset + 3 <= s.count else { return nil }
            length = Int(s[offset + 1]) | Int(s[offset + 2]) << 8
            header = 3
        case 0x4e:
            guard offset + 5 <= s.count else { return nil }
            length = Int(s[offset + 1]) | Int(s[offset + 2]) << 8 | Int(s[offset + 3]) << 16 | Int(s[offset + 4]) << 24
            header = 5
        default: return ([], 1, opcode)
        }
        guard offset + header + length <= s.count else { return nil }
        return (Array(s[(offset + header)..<(offset + header + length)]), header + length, opcode)
    }

    /// `decodeScriptNumber` / `decodeNum2Bin`: little-endian sign-magnitude, the sign the last
    /// byte's top bit.
    static func decodeSignMagnitude(_ data: [UInt8]) -> BigInt {
        var bytes = data
        if bytes.isEmpty { return 0 }
        let negative = bytes[bytes.count - 1] & 0x80 != 0
        bytes[bytes.count - 1] &= 0x7f
        var result = BigInt(0)
        for byte in bytes.reversed() { result = (result << 8) | BigInt(byte) }
        if result == 0 { return 0 }
        return negative ? -result : result
    }

    /// `interpretScriptElement`.
    static func interpret(_ opcode: Int, _ data: [UInt8], _ type: String) -> Value {
        switch abiEncoding(type) {
        case "scriptnum":
            if opcode == 0x00 { return .number(0) }
            if (0x51...0x60).contains(opcode) { return .number(BigInt(opcode - 0x50)) }
            if opcode == 0x4f { return .number(-1) }
            return .number(decodeSignMagnitude(data))
        case "bool":
            if opcode == 0x00 { return .bool(false) }
            if opcode == 0x51 { return .bool(true) }
            return .bool(data != [0x00])
        default:
            if (0x51...0x60).contains(opcode) { return .data(AMMPool.hex([UInt8(opcode - 0x50)])) }
            if opcode == 0x4f { return .data("81") }
            return .data(AMMPool.hex(data))
        }
    }

    /// The code before the state: up to the first OP_RETURN at an opcode boundary.
    static func code(_ artifact: Artifact, _ script: [UInt8]) -> [UInt8] {
        guard !artifact.stateFields.isEmpty else { return script }
        let opReturn = findLastOpReturn(script)
        return opReturn == -1 ? script : Array(script[..<opReturn])
    }

    /// `extractConstructorArgs`: each constructor argument at its slot, every slot walked in
    /// byte order (each occurrence's width shifts the later ones), the value its first slot's.
    static func extractConstructorArgs(_ artifact: Artifact, _ script: [UInt8]) -> [String: Value] {
        let code = code(artifact, script)
        let slots = artifact.constructorSlots.enumerated().sorted {
            $0.element.byteOffset != $1.element.byteOffset ? $0.element.byteOffset < $1.element.byteOffset : $0.offset < $1.offset
        }.map(\.element)
        var result: [String: Value] = [:]
        var assigned: Set<Int> = []
        var shift = 0
        for slot in slots {
            guard let element = readScriptElement(code, slot.byteOffset + shift) else { return result }
            shift += element.total - 1
            if assigned.contains(slot.paramIndex) { continue }
            assigned.insert(slot.paramIndex)
            guard slot.paramIndex < artifact.constructorParams.count else { continue }
            let param = artifact.constructorParams[slot.paramIndex]
            result[param.name] = interpret(element.opcode, element.data, param.type)
        }
        return result
    }

    /// `matchesArtifact`: the script is the template with any pushes at the constructor slots.
    static func matchesArtifact(_ artifact: Artifact, _ script: [UInt8]) -> Bool {
        let code = code(artifact, script)
        let template = artifact.script
        if artifact.constructorSlots.isEmpty { return code == template }
        var seen: Set<Int> = []
        let slots = artifact.constructorSlots.map(\.byteOffset).sorted().filter { seen.insert($0).inserted }

        var templatePos = 0
        var codePos = 0
        for offset in slots {
            let segment = template[templatePos..<offset]
            guard codePos + segment.count <= code.count, code[codePos..<(codePos + segment.count)].elementsEqual(segment) else { return false }
            templatePos = offset + 1
            guard let element = readScriptElement(code, codePos + segment.count) else { return false }
            codePos = codePos + segment.count + element.total
        }
        guard codePos <= code.count else { return false }
        return template[templatePos...].elementsEqual(code[codePos...])
    }

    // MARK: - state.ts

    /// `findLastOpReturn`: the first OP_RETURN at an opcode boundary (pushes skipped), -1 for
    /// none. A PUSHDATA4 length with its top bit set walks off the end here (TS's int32 length
    /// would step backwards).
    static func findLastOpReturn(_ s: [UInt8]) -> Int {
        var offset = 0
        while offset < s.count {
            let opcode = s[offset]
            switch opcode {
            case 0x6a: return offset
            case 0x01...0x4b: offset += 1 + Int(opcode)
            case 0x4c:
                guard offset + 2 <= s.count else { return -1 }
                offset += 2 + Int(s[offset + 1])
            case 0x4d:
                guard offset + 3 <= s.count else { return -1 }
                offset += 3 + (Int(s[offset + 1]) | Int(s[offset + 2]) << 8)
            case 0x4e:
                guard offset + 5 <= s.count else { return -1 }
                offset += 5 + (Int(s[offset + 1]) | Int(s[offset + 2]) << 8 | Int(s[offset + 3]) << 16 | Int(s[offset + 4]) << 24)
            default: offset += 1
            }
        }
        return -1
    }

    /// `extractStateFromScript`: the state after the OP_RETURN; nil with no OP_RETURN; throws
    /// where `deserializeState` does (a truncated field, trailing bytes, a non-push opcode).
    static func extractStateFromScript(_ artifact: Artifact, _ script: [UInt8]) throws -> [String: Value]? {
        if artifact.stateFields.isEmpty { return nil }
        let opReturn = findLastOpReturn(script)
        if opReturn == -1 { return nil }
        return try deserializeState(artifact.stateFields, Array(script[(opReturn + 1)...]))
    }

    /// `deserializeState`: every field, exactly; fails closed.
    static func deserializeState(_ fields: [(name: String, type: String)], _ s: [UInt8]) throws -> [String: Value] {
        var result: [String: Value] = [:]
        var offset = 0
        for field in fields {
            if let width = stateWidth(field.type) {
                guard offset + width.size <= s.count else { throw StateError() }
                let data = Array(s[offset..<(offset + width.size)])
                switch width.encoding {
                case "bool1": result[field.name] = .bool(data != [0x00])
                case "num2bin-le8": result[field.name] = .number(decodeSignMagnitude(data))
                default: result[field.name] = .data(AMMPool.hex(data))
                }
                offset += width.size
            } else {
                guard offset < s.count else { throw StateError() }
                let opcode = s[offset]
                let header: Int
                let length: Int
                switch opcode {
                case 0x00...0x4b:
                    header = 1
                    length = Int(opcode)
                case 0x4c:
                    guard offset + 2 <= s.count else { throw StateError() }
                    header = 2
                    length = Int(s[offset + 1])
                case 0x4d:
                    guard offset + 3 <= s.count else { throw StateError() }
                    header = 3
                    length = Int(s[offset + 1]) | Int(s[offset + 2]) << 8
                case 0x4e:
                    guard offset + 5 <= s.count else { throw StateError() }
                    header = 5
                    length = Int(s[offset + 1]) | Int(s[offset + 2]) << 8 | Int(s[offset + 3]) << 16 | Int(s[offset + 4]) << 24
                default:
                    throw StateError()
                }
                guard offset + header + length <= s.count else { throw StateError() }
                result[field.name] = .data(AMMPool.hex(Array(s[(offset + header)..<(offset + header + length)])))
                offset += header + length
            }
        }
        guard offset == s.count else { throw StateError() }
        return result
    }

    static func hexBytes(_ text: String) -> [UInt8] {
        var out: [UInt8] = []
        var high: UInt8?
        for byte in text.utf8 {
            let value: UInt8 = switch byte {
            case 0x30...0x39: byte - 0x30
            case 0x61...0x66: byte - 0x61 + 10
            default: preconditionFailure("pool artifact: not hex")
            }
            if let h = high { out.append(h << 4 | value); high = nil } else { high = value }
        }
        return out
    }
}
