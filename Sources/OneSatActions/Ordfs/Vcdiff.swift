/// RFC 3284 VCDIFF delta encoding, in pure Swift.
///
/// Counterpart of `packages/actions/src/ordfs/vcdiff.ts`, which wraps `xdelta3-wasm`. The wire
/// profile is the same: header `D6 C3 C4 00` with `Hdr_Indicator` 0 (no secondary compression, no
/// custom code table, no application header).
///
/// Decoder: windows may use `VCD_SOURCE`; `VCD_TARGET` is refused. xdelta3's `VCD_ADLER32`
/// window extension (`Win_Indicator` bit `0x04`) is accepted and verified. `Delta_Indicator` must
/// be 0. Instructions use the RFC default code table (near cache 4, same cache 3). Every read is
/// bounds-checked, and total output is capped at ``maximumOutputByteCount``.
///
/// Encoder: greedy matching over a rolling hash of the source and the target already emitted.
/// It writes only explicit-size opcodes (`RUN 0`, `ADD 0`, `COPY 0 mode 0`), absolute (`VCD_SELF`)
/// addresses, and no checksum, so any RFC 3284 decoder, xdelta3 included, can read it.
public enum Vcdiff {
    /// The four header bytes: `V C D` with the high bit set, then version 0.
    public static let magic: [UInt8] = [0xd6, 0xc3, 0xc4, 0x00]

    /// Largest total target the decoder will produce.
    public static let maximumOutputByteCount = 256 * 1024 * 1024

    /// Largest target window the encoder writes; xdelta3's default window size.
    static let encoderWindowByteCount = 1 << 23

    // MARK: Header checks

    /// Throws unless `delta` starts with the plain RFC header this package reads and writes.
    public static func assertPlainRFC(_ delta: [UInt8]) throws {
        guard delta.count >= 5 else {
            throw VcdiffError("vcdiff delta too short")
        }
        guard delta[0] == 0xd6, delta[1] == 0xc3, delta[2] == 0xc4 else {
            throw VcdiffError("bad vcdiff magic")
        }
        guard delta[3] == 0x00 else {
            throw VcdiffError("unsupported vcdiff version \(delta[3])")
        }
        guard delta[4] == 0x00 else {
            throw VcdiffError(
                "vcdiff Hdr_Indicator \(delta[4]) must be 0 (no secondary compression, no app header)"
            )
        }
    }

    // MARK: Decode

    /// Applies `delta` to `source` and returns the target bytes.
    public static func decode(_ delta: [UInt8], source: [UInt8] = []) throws -> [UInt8] {
        try assertPlainRFC(delta)
        var reader = Reader(bytes: delta, start: 5, end: delta.count)
        var output: [UInt8] = []
        while !reader.isAtEnd {
            try decodeWindow(&reader, source: source, output: &output)
        }
        return output
    }

    private static let vcdSource: UInt8 = 0x01
    private static let vcdTarget: UInt8 = 0x02
    private static let vcdAdler32: UInt8 = 0x04

    private static func decodeWindow(
        _ reader: inout Reader,
        source: [UInt8],
        output: inout [UInt8]
    ) throws {
        let indicator = try reader.byte("Win_Indicator")
        if indicator & vcdTarget != 0 {
            throw VcdiffError("vcdiff VCD_TARGET windows are not supported")
        }
        guard indicator & ~(vcdSource | vcdAdler32) == 0 else {
            throw VcdiffError("vcdiff Win_Indicator \(indicator) has unknown bits")
        }

        var segment: ArraySlice<UInt8> = []
        if indicator & vcdSource != 0 {
            let length = try reader.size("source segment size")
            let position = try reader.size("source segment position")
            guard position <= source.count, length <= source.count - position else {
                throw VcdiffError("vcdiff source segment out of range")
            }
            segment = source[position..<(position + length)]
        }

        let encodingLength = try reader.size("delta encoding length")
        guard encodingLength <= reader.remaining else {
            throw VcdiffError("vcdiff truncated delta encoding")
        }
        let encodingEnd = reader.position + encodingLength
        var body = Reader(bytes: reader.bytes, start: reader.position, end: encodingEnd)
        reader.position = encodingEnd

        let targetLength = try body.size("target window size")
        guard targetLength <= maximumOutputByteCount - output.count else {
            throw VcdiffError("vcdiff output exceeds \(maximumOutputByteCount) bytes")
        }
        let deltaIndicator = try body.byte("Delta_Indicator")
        guard deltaIndicator == 0 else {
            throw VcdiffError("vcdiff Delta_Indicator \(deltaIndicator) must be 0 (no secondary compression)")
        }
        let dataLength = try body.size("data section length")
        let instructionLength = try body.size("instructions section length")
        let addressLength = try body.size("addresses section length")
        var expectedChecksum: UInt32?
        if indicator & vcdAdler32 != 0 {
            let b = try body.bytes(4, "adler32 checksum")
            expectedChecksum = b.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        guard dataLength <= body.remaining,
              instructionLength <= body.remaining - dataLength,
              addressLength == body.remaining - dataLength - instructionLength else {
            throw VcdiffError("vcdiff section lengths do not match the delta encoding length")
        }
        var data = Reader(bytes: body.bytes, start: body.position, end: body.position + dataLength)
        var instructions = Reader(
            bytes: body.bytes,
            start: data.end,
            end: data.end + instructionLength
        )
        var addresses = Reader(bytes: body.bytes, start: instructions.end, end: body.end)

        let windowStart = output.count
        output.reserveCapacity(output.count + targetLength)
        var cache = AddressCache()
        let sourceLength = segment.count
        let sourceBase = segment.startIndex

        func execute(_ half: HalfInstruction) throws {
            var size = Int(half.size)
            if size == 0 {
                size = try instructions.size("instruction size")
            }
            let written = output.count - windowStart
            guard size <= targetLength - written else {
                throw VcdiffError("vcdiff instruction overruns the target window")
            }
            switch half.type {
            case .noop:
                break
            case .add:
                output.append(contentsOf: try data.bytes(size, "ADD data"))
            case .run:
                let byte = try data.byte("RUN data")
                output.append(contentsOf: repeatElement(byte, count: size))
            case .copy:
                let here = sourceLength + written
                let address = try cache.decode(here: here, mode: Int(half.mode), addresses: &addresses)
                guard address < here else {
                    throw VcdiffError("vcdiff COPY address \(address) is not before \(here)")
                }
                if address + size <= sourceLength {
                    output.append(contentsOf: source[(sourceBase + address)..<(sourceBase + address + size)])
                } else if address >= sourceLength, address - sourceLength + size <= written {
                    let from = windowStart + address - sourceLength
                    output.append(contentsOf: Array(output[from..<(from + size)]))
                } else {
                    // Overlapping (run-like) copies, or a copy that spans S and T: byte by byte
                    // through the RFC's combined string U = S + T.
                    for offset in 0..<size {
                        let u = address + offset
                        let byte = u < sourceLength
                            ? source[sourceBase + u]
                            : output[windowStart + u - sourceLength]
                        output.append(byte)
                    }
                }
            }
        }

        while !instructions.isAtEnd {
            let entry = CodeTable.default[Int(try instructions.byte("instruction"))]
            if entry.0.type != .noop {
                try execute(entry.0)
            }
            if entry.1.type != .noop {
                try execute(entry.1)
            }
        }

        guard output.count - windowStart == targetLength else {
            throw VcdiffError("vcdiff window produced \(output.count - windowStart) of \(targetLength) bytes")
        }
        guard data.isAtEnd, addresses.isAtEnd else {
            throw VcdiffError("vcdiff window has unused data or addresses")
        }
        if let expectedChecksum {
            let actual = adler32(output[windowStart...])
            guard actual == expectedChecksum else {
                throw VcdiffError("vcdiff adler32 checksum mismatch")
            }
        }
    }

    /// Adler-32 as xdelta3 writes it for `VCD_ADLER32`.
    static func adler32<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        let mod: UInt32 = 65521
        var a: UInt32 = 1
        var b: UInt32 = 0
        var pending = 0
        for byte in bytes {
            a += UInt32(byte)
            b += a
            pending += 1
            if pending == 5552 {
                a %= mod
                b %= mod
                pending = 0
            }
        }
        return ((b % mod) << 16) | (a % mod)
    }

    // MARK: Encode

    /// Encodes `target` as a delta against `source` (empty source: a self-contained delta).
    public static func encode(_ target: [UInt8], source: [UInt8] = []) -> [UInt8] {
        var out = magic + [0x00]
        let matcher = Matcher(source: source, target: target)
        var windowStart = 0
        repeat {
            let windowEnd = min(target.count, windowStart + encoderWindowByteCount)
            out += matcher.encodeWindow(windowStart..<windowEnd)
            windowStart = windowEnd
        } while windowStart < target.count
        return out
    }

    static func appendSize(_ value: Int, to out: inout [UInt8]) {
        precondition(value >= 0)
        var groups: [UInt8] = [UInt8(value & 0x7f)]
        var rest = value >> 7
        while rest > 0 {
            groups.append(UInt8(rest & 0x7f) | 0x80)
            rest >>= 7
        }
        out.append(contentsOf: groups.reversed())
    }
}

/// A VCDIFF format violation, malformed delta, or unsupported feature.
public struct VcdiffError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

// MARK: - Decoder internals

private struct Reader {
    let bytes: [UInt8]
    var position: Int
    let end: Int

    init(bytes: [UInt8], start: Int, end: Int) {
        self.bytes = bytes
        self.position = start
        self.end = end
    }

    var isAtEnd: Bool { position >= end }
    var remaining: Int { end - position }

    mutating func byte(_ what: String) throws -> UInt8 {
        guard position < end else {
            throw VcdiffError("vcdiff truncated \(what)")
        }
        defer { position += 1 }
        return bytes[position]
    }

    mutating func bytes(_ count: Int, _ what: String) throws -> ArraySlice<UInt8> {
        guard count <= remaining else {
            throw VcdiffError("vcdiff truncated \(what)")
        }
        defer { position += count }
        return bytes[position..<(position + count)]
    }

    /// RFC 3284 base-128 big-endian integer, bounded to at most nine bytes (63 bits).
    mutating func size(_ what: String) throws -> Int {
        var value = 0
        for _ in 0..<9 {
            let b = try byte(what)
            value = (value << 7) | Int(b & 0x7f)
            if b & 0x80 == 0 {
                return value
            }
        }
        throw VcdiffError("vcdiff integer overflow in \(what)")
    }
}

private enum InstructionType: UInt8 {
    case noop = 0
    case add = 1
    case run = 2
    case copy = 3
}

private struct HalfInstruction {
    let type: InstructionType
    let size: UInt8
    let mode: UInt8
}

/// The RFC 3284 section 5.6 default instruction code table.
private enum CodeTable {
    static let nearSize = 4
    static let sameSize = 3

    static let `default`: [(HalfInstruction, HalfInstruction)] = {
        let noop = HalfInstruction(type: .noop, size: 0, mode: 0)
        var table: [(HalfInstruction, HalfInstruction)] = []
        table.append((HalfInstruction(type: .run, size: 0, mode: 0), noop))
        for size in 0...17 {
            table.append((HalfInstruction(type: .add, size: UInt8(size), mode: 0), noop))
        }
        for mode in 0...8 {
            table.append((HalfInstruction(type: .copy, size: 0, mode: UInt8(mode)), noop))
            for size in 4...18 {
                table.append((HalfInstruction(type: .copy, size: UInt8(size), mode: UInt8(mode)), noop))
            }
        }
        for mode in 0...5 {
            for addSize in 1...4 {
                for copySize in 4...6 {
                    table.append((
                        HalfInstruction(type: .add, size: UInt8(addSize), mode: 0),
                        HalfInstruction(type: .copy, size: UInt8(copySize), mode: UInt8(mode))
                    ))
                }
            }
        }
        for mode in 6...8 {
            for addSize in 1...4 {
                table.append((
                    HalfInstruction(type: .add, size: UInt8(addSize), mode: 0),
                    HalfInstruction(type: .copy, size: 4, mode: UInt8(mode))
                ))
            }
        }
        for mode in 0...8 {
            table.append((
                HalfInstruction(type: .copy, size: 4, mode: UInt8(mode)),
                HalfInstruction(type: .add, size: 1, mode: 0)
            ))
        }
        precondition(table.count == 256)
        return table
    }()
}

/// RFC 3284 section 5.1 address caches, reset at the start of every window.
private struct AddressCache {
    var near = [Int](repeating: 0, count: CodeTable.nearSize)
    var nextSlot = 0
    var same = [Int](repeating: 0, count: CodeTable.sameSize * 256)

    mutating func decode(here: Int, mode: Int, addresses: inout Reader) throws -> Int {
        let address: Int
        switch mode {
        case 0:
            address = try addresses.size("COPY address")
        case 1:
            let offset = try addresses.size("COPY address")
            guard offset <= here else {
                throw VcdiffError("vcdiff VCD_HERE address underflow")
            }
            address = here - offset
        case 2..<(2 + CodeTable.nearSize):
            let offset = try addresses.size("COPY address")
            let (sum, overflow) = near[mode - 2].addingReportingOverflow(offset)
            guard !overflow else {
                throw VcdiffError("vcdiff near address overflow")
            }
            address = sum
        default:
            let m = mode - (2 + CodeTable.nearSize)
            address = same[m * 256 + Int(try addresses.byte("COPY address"))]
        }
        near[nextSlot] = address
        nextSlot = (nextSlot + 1) % CodeTable.nearSize
        same[address % same.count] = address
        return address
    }
}

// MARK: - Encoder internals

/// Greedy matcher: a polynomial rolling hash over `blockSize`-byte blocks indexes every source
/// position and every target position already emitted in the current window.
private struct Matcher {
    static let blockSize = 8
    static let minimumRun = 8

    let source: [UInt8]
    let target: [UInt8]
    private let sourceTable: [Int32]
    private let tableMask: Int

    private static let base: UInt32 = 0x0100_0193
    /// `base ^ (blockSize - 1)`, to drop the leading byte when rolling.
    private static let leadingFactor: UInt32 = {
        var f: UInt32 = 1
        for _ in 1..<blockSize { f = f &* base }
        return f
    }()

    init(source: [UInt8], target: [UInt8]) {
        self.source = source
        self.target = target
        let span = source.count + min(target.count, Vcdiff.encoderWindowByteCount)
        var size = 1 << 10
        while size < 2 * span, size < 1 << 22 {
            size <<= 1
        }
        self.tableMask = size - 1
        var table = [Int32](repeating: -1, count: source.count >= Self.blockSize ? size : 0)
        if source.count >= Self.blockSize {
            var h = Self.hash(source, 0)
            for position in 0...(source.count - Self.blockSize) {
                if position > 0 {
                    h = Self.roll(h, out: source[position - 1], in: source[position + Self.blockSize - 1])
                }
                let slot = Int(h) & (size - 1)
                if table[slot] < 0 {
                    table[slot] = Int32(truncatingIfNeeded: position)
                }
            }
        }
        self.sourceTable = table
    }

    static func hash(_ bytes: [UInt8], _ start: Int) -> UInt32 {
        var h: UInt32 = 0
        for i in start..<(start + blockSize) {
            h = h &* base &+ UInt32(bytes[i])
        }
        return h
    }

    static func roll(_ h: UInt32, out: UInt8, in incoming: UInt8) -> UInt32 {
        (h &- UInt32(out) &* leadingFactor) &* base &+ UInt32(incoming)
    }

    func encodeWindow(_ window: Range<Int>) -> [UInt8] {
        let sourceLength = source.count
        let start = window.lowerBound
        let end = window.upperBound
        var data: [UInt8] = []
        var instructions: [UInt8] = []
        var addresses: [UInt8] = []
        var targetTable = [Int32](repeating: -1, count: tableMask + 1)
        var pendingAdd = start
        var position = start
        var indexed = start
        var rolling: UInt32 = 0
        var rollingAt = -1

        func hashAt(_ p: Int) -> UInt32 {
            if rollingAt == p - 1, p > start {
                rolling = Self.roll(rolling, out: target[p - 1], in: target[p + Self.blockSize - 1])
            } else {
                rolling = Self.hash(target, p)
            }
            rollingAt = p
            return rolling
        }

        func flushAdd(upTo p: Int) {
            guard p > pendingAdd else { return }
            instructions.append(1)
            Vcdiff.appendSize(p - pendingAdd, to: &instructions)
            data.append(contentsOf: target[pendingAdd..<p])
            pendingAdd = p
        }

        // Window-local target positions are indexed lazily, up to (not including) `limit`.
        func index(upTo limit: Int) {
            let last = min(limit, end - Self.blockSize + 1)
            while indexed < last {
                let h = Self.hash(target, indexed)
                targetTable[Int(h) & tableMask] = Int32(truncatingIfNeeded: indexed - start)
                indexed += 1
            }
            indexed = max(indexed, limit)
        }

        while position < end {
            var bestLength = 0
            var bestAddress = 0
            var bestBack = 0

            if end - position >= Self.blockSize {
                let h = hashAt(position)
                let slot = Int(h) & tableMask
                index(upTo: position)

                if !sourceTable.isEmpty, sourceTable[slot] >= 0 {
                    let candidate = Int(sourceTable[slot])
                    var length = 0
                    while position + length < end, candidate + length < sourceLength,
                          target[position + length] == source[candidate + length] {
                        length += 1
                    }
                    if length >= Self.blockSize {
                        var back = 0
                        while position - back > pendingAdd, candidate - back > 0,
                              target[position - back - 1] == source[candidate - back - 1] {
                            back += 1
                        }
                        bestLength = length + back
                        bestAddress = candidate - back
                        bestBack = back
                    }
                }
                if targetTable[slot] >= 0 {
                    let candidate = start + Int(targetTable[slot])
                    var length = 0
                    while position + length < end, target[position + length] == target[candidate + length] {
                        length += 1
                    }
                    if length >= Self.blockSize {
                        var back = 0
                        while position - back > pendingAdd, candidate - back > start,
                              target[position - back - 1] == target[candidate - back - 1] {
                            back += 1
                        }
                        if length + back > bestLength {
                            bestLength = length + back
                            bestAddress = sourceLength + (candidate - back - start)
                            bestBack = back
                        }
                    }
                }
            }

            var run = 1
            while position + run < end, target[position + run] == target[position] {
                run += 1
            }
            if run >= Self.minimumRun, run >= bestLength - bestBack {
                flushAdd(upTo: position)
                instructions.append(0)
                Vcdiff.appendSize(run, to: &instructions)
                data.append(target[position])
                position += run
                pendingAdd = position
                continue
            }

            if bestLength > 0 {
                let copyStart = position - bestBack
                flushAdd(upTo: copyStart)
                instructions.append(19)
                Vcdiff.appendSize(bestLength, to: &instructions)
                Vcdiff.appendSize(bestAddress, to: &addresses)
                position = copyStart + bestLength
                pendingAdd = position
                continue
            }

            position += 1
        }
        flushAdd(upTo: end)

        var body: [UInt8] = []
        Vcdiff.appendSize(end - start, to: &body)
        body.append(0x00)
        Vcdiff.appendSize(data.count, to: &body)
        Vcdiff.appendSize(instructions.count, to: &body)
        Vcdiff.appendSize(addresses.count, to: &body)
        body += data
        body += instructions
        body += addresses

        var window: [UInt8] = []
        if sourceLength > 0 {
            window.append(0x01)
            Vcdiff.appendSize(sourceLength, to: &window)
            Vcdiff.appendSize(0, to: &window)
        } else {
            window.append(0x00)
        }
        Vcdiff.appendSize(body.count, to: &window)
        return window + body
    }
}
