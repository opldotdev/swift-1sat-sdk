import BSVCore
import BSVKeys
import BSVScript

/// Marketplace listing lock: cancel with the seller key, or buy by paying the listed price.
///
/// Matches `@1sat/templates` `OrdLock`.
public enum OrdLock {
    public static let prefix = TimeLock.prefix

    public static let suffix = Array(hex: "615179547a75537a537a537a0079537a75527a527a7575615579008763567901c161517957795779210ac407f0e4bd44bfc207355a778b046225a7068fc59ee7eda43ad905aadbffc800206c266b30e6a1319c66dc401e5bd6b432ba49688eecd118297041da8074ce081059795679615679aa0079610079517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e01007e81517a75615779567956795679567961537956795479577995939521414136d08c5ed2bf3ba048afe6dcaebafeffffffffffffffffffffffffffffff00517951796151795179970079009f63007952799367007968517a75517a75517a7561527a75517a517951795296a0630079527994527a75517a6853798277527982775379012080517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e01205279947f7754537993527993013051797e527e54797e58797e527e53797e52797e57797e0079517a75517a75517a75517a75517a75517a75517a75517a75517a75517a75517a75517a75517a756100795779ac517a75517a75517a75517a75517a75517a75517a75517a75517a7561517a75517a756169587951797e58797eaa577961007982775179517958947f7551790128947f77517a75517a75618777777777777777777767557951876351795779a9876957795779ac777777777777777767006868")

    public struct Data: Equatable, Sendable {
        public let seller: String
        public let price: UInt64
        public let payout: [UInt8]
    }

    public static func lock(
        cancelAddress: String,
        payAddress: String,
        price: UInt64
    ) throws -> Script {
        let cancel = try Address(cancelAddress)
        let pay = try Address(payAddress)
        let payScript = try Script.payToPublicKeyHash(
            pay,
            maximumByteCount: TemplateScript.maximumByteCount
        )
        var script = try TemplateScript.script(bytes: prefix)
        try TemplateScript.appendPush(cancel.publicKeyHash.bytes, to: &script)
        try TemplateScript.appendPush(buildOutput(satoshis: price, script: payScript), to: &script)
        return try TemplateScript.concatenating([script.bytes, suffix])
    }

    /// 8-byte little-endian satoshis + CompactSize script length + script.
    public static func buildOutput(satoshis: UInt64, script: Script) -> [UInt8] {
        var bytes: [UInt8] = (0..<8).map { UInt8(truncatingIfNeeded: satoshis >> ($0 * 8)) }
        bytes.append(contentsOf: CompactSize.encode(UInt64(script.byteCount)))
        bytes.append(contentsOf: script.bytes)
        return bytes
    }

    public static func isOrdLock(_ script: Script) -> Bool {
        decode(script) != nil
    }

    public static func decode(_ script: Script, network: BitcoinNetwork = .mainnet) -> Data? {
        guard let prefixIndex = TemplateScript.indexOf(script.bytes, prefix) else { return nil }
        guard let suffixIndex = TemplateScript.indexOf(
            script.bytes,
            suffix,
            from: prefixIndex + prefix.count
        ) else { return nil }

        let dataBytes = Array(script.bytes[(prefixIndex + prefix.count)..<suffixIndex])
        guard !dataBytes.isEmpty,
              let dataScript = try? TemplateScript.script(bytes: dataBytes),
              let operations = try? TemplateScript.operations(dataScript),
              operations.count >= 2,
              let sellerHash = operations[0].pushedData, sellerHash.count == 20,
              let payout = operations[1].pushedData, payout.count >= 9
        else { return nil }

        var price: UInt64 = 0
        for index in 0..<8 {
            price |= UInt64(payout[index]) << (index * 8)
        }

        guard let publicKeyHash = try? Hash160(sellerHash) else { return nil }
        let seller = Address(publicKeyHash: publicKeyHash, network: network)
        return Data(seller: seller.description, price: price, payout: payout)
    }
}
