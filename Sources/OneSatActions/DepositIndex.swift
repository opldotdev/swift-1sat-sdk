import Foundation
import BSVCore
import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet
import OneSatClient
import OneSatTemplates
import ToolboxActions
import ToolboxCore

/// What arrived at a deposit address, filed the way `@1sat/actions` `internalizeBeef` files it
/// after the `@1sat/wallet` indexers have parsed the transaction:
///
/// - plain BSV (`FundIndexer`, 2 sats or more) goes to `1sat-deposit` for `sweepDeposit`;
/// - a 1-sat ordinal (`OriginIndexer`) goes to `1sat`, or `opns` when its origin is an OpNS name,
///   with BRC-147 tags and customInstructions; a transfer's origin is read from OrdFS, and a
///   failure to read it fails the transaction so the sync retries it;
/// - a BSV-21 output (`Bsv21Indexer`) goes to `bsv21` (`mnee` for MNEE) with token CI and the
///   `bsv21 <id>` label.
///
/// Every output records the protocol its address was derived under, so legacy `p 1sat`
/// deposits are signed with the key that owns them.
enum DepositIndex {
    struct Indexed {
        var outputs: [WalletInternalizeOutput] = []
        var labels: [String] = []
        var description: String = ""
    }

    /// `MNEE_TOKEN_ID`, filed in its own basket by `Bsv21Indexer`.
    static let mneeTokenID = "ae59f3b898ec61acbdb6cc7a245fabeded0c094bf046f35206a3aec60ef88127_0"
    static let mneeBasket = "mnee"
    static let opnsType = "application/op-ns"

    static func classify(
        _ tx: Transaction,
        txid: String,
        graph: BEEF,
        derived: [DepositDerivation],
        network: BitcoinNetwork,
        assets: any DepositAssetSource
    ) async throws -> Indexed {
        var indexed = Indexed()
        let actionID = TrackedAction.randomActionID()
        var parts: [String] = []
        var sats: UInt64 = 0
        var labels: [String] = []
        var spends: [Spend]?

        // Output `vout`'s first satoshi, for ordinal origin tracking.
        var positions: [UInt64] = []
        var cumulative: UInt64 = 0
        for output in tx.outputs {
            positions.append(cumulative)
            cumulative &+= output.satoshis
        }

        for (index, output) in tx.outputs.enumerated() {
            let vout = UInt32(index)
            let script = output.lockingScript
            let inscription = output.satoshis == 1 ? Inscription.decode(script) : nil
            guard let ownerHash = owner(script, inscription: inscription),
                  let derivation = derived.first(where: { $0.publicKeyHash == ownerHash })
            else { continue }
            let idTag = "id:\(actionID)_\(vout)"
            let outpoint = "\(txid).\(vout)"
            let mapTags = mapNameTags(script)

            if output.satoshis >= 2 {
                // `FundIndexer` → plain deposit branch of `buildInternalizeOutput`.
                indexed.outputs.append(try insertion(
                    vout: vout,
                    basket: OneSatConstants.depositBasket,
                    tags: [idTag],
                    customInstructions: try CustomInstructions(
                        protocolID: derivation.protocolID,
                        keyID: derivation.keyID,
                        counterparty: .self
                    ).encoded(includeSelfCounterparty: true)
                ))
                sats &+= output.satoshis
                continue
            }
            guard output.satoshis == 1 else { continue }

            if let token = inscription.flatMap({ _ in BSV21.decode(script) }) {
                let filed = try await bsv21(
                    token,
                    outpoint: "\(txid)_\(vout)",
                    derivation: derivation,
                    extraTags: mapTags,
                    idTag: idTag,
                    assets: assets
                )
                indexed.outputs.append(try insertion(
                    vout: vout,
                    basket: filed.basket,
                    tags: filed.tags,
                    customInstructions: filed.customInstructions
                ))
                parts.append(filed.description)
                if !labels.contains(filed.label) { labels.append(filed.label) }
                continue
            }
            // `OriginIndexer` leaves tick-based BSV-20 alone. TS then files the sat in the deposit
            // basket, where `sweepDeposit` would spend the token as fee; it is left out here.
            if inscription?.contentType == "application/bsv-20" { continue }

            if spends == nil {
                spends = try await loadSpends(tx, graph: graph, assets: assets)
            }
            let filed = try await ordinal(
                outpoint: outpoint,
                position: positions[index],
                spends: spends ?? [],
                inscription: inscription,
                mapTags: mapTags,
                currentMap: currentMap(script),
                assets: assets
            )
            let tags = filed.tags + [idTag]
            indexed.outputs.append(try insertion(
                vout: vout,
                basket: filed.basket,
                tags: tags,
                customInstructions: OrdinalRemittance.buildCustomInstructions(
                    protocolID: derivation.protocolID,
                    keyID: derivation.keyID,
                    counterparty: "self",
                    tags: tags,
                    name: tags.first(where: { $0.hasPrefix("name:") }).map { String($0.dropFirst(5)) }
                )
            ))
            parts.append(filed.basket == OneSatConstants.opnsBasket ? "OPNS name" : "ordinal")
        }

        indexed.labels = labels
        indexed.description = SyncAddresses.buildDescription(parts: parts, sats: sats)
        return indexed
    }

    // MARK: - Ordinals (OriginIndexer, OpNSIndexer, MapIndexer)

    struct Spend: Sendable {
        let outpoint: String
        let satoshis: UInt64
    }

    struct Filed {
        let basket: String
        let tags: [String]
    }

    /// `resolveOrigins`: a 1-sat input sitting exactly at this output's first satoshi means a
    /// transfer, whose origin and type OrdFS knows; anything else makes this output the origin.
    static func ordinal(
        outpoint: String,
        position: UInt64,
        spends: [Spend],
        inscription: Inscription?,
        mapTags: [String],
        currentMap: [String: JSONValue]?,
        assets: any DepositAssetSource
    ) async throws -> Filed {
        var source: String?
        var satsIn: UInt64 = 0
        for spend in spends {
            if satsIn == position, spend.satoshis == 1 {
                source = spend.outpoint
                break
            }
            satsIn &+= spend.satoshis
            if satsIn > position { break }
        }

        var origin = outpoint
        var originType = inscription?.contentType
        var originMap = currentMap
        var originContent: String?
        if let source {
            // An ordinal must not be ingested without its origin: any error here fails the
            // transaction and the cursor holds, as in TS.
            let metadata = try await assets.ordinalMetadata(outpoint: source, seq: 0)
            origin = nonempty(metadata.origin) ?? source
            if let inherited = metadata.map {
                originMap = inherited.merging(currentMap ?? [:]) { _, current in current }
            }
            originType = metadata.contentType
            let base = baseType(metadata.contentType) ?? ""
            let isText = base.hasPrefix("text/") || base == "application/json" || base == opnsType
            if isText, let length = metadata.contentLength, length <= 1_000,
               let data = try? await assets.ordinalContent(outpoint: origin)
            {
                originContent = String(decoding: data, as: UTF8.self)
            }
        }

        let originIsOpns = baseType(originType) == opnsType
        let basket = originIsOpns ? OneSatConstants.opnsBasket : OneSatConstants.ordinalsBasket
        let originTags = OrdinalTags.fromMetadata(origin: origin, contentType: originType, map: originMap)

        // `OpNSIndexer.parse` claims an op-ns envelope on this output; `summarize` keeps the claim
        // only when the origin is a name, and names it from this envelope only at the origin.
        let parsedOpns = baseType(inscription?.contentType) == opnsType
        let parseTags = parsedOpns
            ? opnsName(inscription?.content).map { ["name:\($0)"] } ?? []
            : []
        var opnsTags: [String] = []
        if originIsOpns {
            opnsTags = origin == outpoint ? parseTags : []
            if !opnsTags.contains(where: { $0.hasPrefix("name:") }),
               let name = opnsName(originContent.map { Array($0.utf8) })
            {
                opnsTags.append("name:\(name)")
            }
        }

        // `collectTags` walks `txo.data` in insertion order: origin, the op-ns claim when parse
        // made it, MAP, then a claim `summarize` added.
        var tags = originTags
        if parsedOpns { tags += opnsTags }
        tags += mapTags
        if !parsedOpns { tags += opnsTags }
        return Filed(basket: basket, tags: tags)
    }

    /// The source of every input: from the BEEF, else `getRawTx`.
    static func loadSpends(
        _ tx: Transaction,
        graph: BEEF,
        assets: any DepositAssetSource
    ) async throws -> [Spend] {
        let limits = WalletBEEFLimits.standard.transactionLimits
        var spends: [Spend] = []
        var fetched: [TransactionID: Transaction] = [:]
        for input in tx.inputs {
            let sourceID = input.previousOutput.transactionID
            let vout = Int(input.previousOutput.outputIndex)
            let source: Transaction
            if let found = try graph.transaction(for: sourceID, limits: limits) ?? fetched[sourceID] {
                source = found
            } else {
                source = try Transaction(
                    bytes: try await assets.rawTransaction(txid: sourceID.displayHex),
                    limits: limits
                )
                fetched[sourceID] = source
            }
            guard source.outputs.indices.contains(vout) else {
                throw OneSatActionError.missingSourceTransaction(inputIndex: spends.count)
            }
            spends.append(Spend(
                outpoint: "\(sourceID.displayHex).\(vout)",
                satoshis: source.outputs[vout].satoshis
            ))
        }
        return spends
    }

    // MARK: - BSV-21 (Bsv21Indexer)

    struct FiledToken {
        let basket: String
        let tags: [String]
        let customInstructions: String
        let label: String
        let description: String
    }

    static func bsv21(
        _ token: BSV21,
        outpoint: String,
        derivation: DepositDerivation,
        extraTags: [String],
        idTag: String,
        assets: any DepositAssetSource
    ) async throws -> FiledToken {
        let data = token.tokenData
        let tokenID = data.tokenID ?? outpoint
        let isDeploy = data.operation == .deployMint || data.operation == .deployAuth
        let isAuth = data.operation == .auth || data.operation == .deployAuth
        let amount = data.amount.flatMap { UInt64($0) } ?? 0
        var symbol = data.symbol
        var decimals = data.decimals ?? 0
        var icon = data.icon
        if isDeploy {
            icon = resolveIcon(icon, tokenID: tokenID)
        } else if let details = try await assets.tokenDetails(tokenID: tokenID) {
            symbol = details.symbol
            icon = resolveIcon(details.icon, tokenID: tokenID)
            decimals = details.decimals
        }

        var tags = ["bsv21:\(tokenID)"]
        if isAuth { tags.append(Bsv21Remittance.authTag) }
        if isDeploy { tags.append(Bsv21Remittance.deployTag) }
        tags += extraTags
        tags.append(idTag)

        let customInstructions = Bsv21Remittance.buildCustomInstructions(
            token: Bsv21Remittance.Fields(
                id: tokenID,
                amt: String(amount),
                op: data.operation.rawValue,
                symbol: nonempty(symbol),
                decimals: String(decimals),
                icon: nonempty(icon)
            ),
            protocolID: derivation.protocolID,
            keyID: derivation.keyID,
            counterparty: "self"
        )
        let shown = jsNumber(Double(amount) / pow(10, Double(decimals)))
        return FiledToken(
            basket: tokenID == mneeTokenID ? mneeBasket : OneSatConstants.bsv21Basket,
            tags: tags,
            customInstructions: customInstructions,
            label: "bsv21 \(tokenID)",
            description: "\(shown) \(nonempty(symbol) ?? "tokens")"
        )
    }

    /// `resolveIcon`: `_<vout>` is relative to the token's deploy transaction.
    static func resolveIcon(_ icon: String?, tokenID: String) -> String? {
        guard let icon, icon.hasPrefix("_") else { return icon }
        return String(tokenID.prefix(64)) + icon
    }

    /// `String(Number)` for the values a token amount takes.
    static func jsNumber(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e21 {
            return String(format: "%.0f", value)
        }
        return "\(value)"
    }

    // MARK: - Script reading

    /// `parseAddress(script, 0)`, then `InscriptionIndexer`'s suffix owner (after `OP_ENDIF`, or
    /// after an `OP_CODESEPARATOR` there).
    static func owner(_ script: Script, inscription: Inscription?) -> [UInt8]? {
        if let hash = p2pkhHash(script.bytes, at: 0) { return hash }
        guard let suffix = inscription?.scriptSuffix?.bytes else { return nil }
        if let hash = p2pkhHash(suffix, at: 0) { return hash }
        if suffix.first == Opcode.codeSeparator.rawValue { return p2pkhHash(suffix, at: 1) }
        return nil
    }

    /// `OP_DUP OP_HASH160 <20> OP_EQUALVERIFY OP_CHECKSIG` starting at byte `offset`.
    static func p2pkhHash(_ bytes: [UInt8], at offset: Int) -> [UInt8]? {
        guard bytes.count >= offset + 25,
              bytes[offset] == 0x76, bytes[offset + 1] == 0xa9, bytes[offset + 2] == 0x14,
              bytes[offset + 23] == 0x88, bytes[offset + 24] == 0xac
        else { return nil }
        return Array(bytes[(offset + 3)..<(offset + 23)])
    }

    /// `MapIndexer` over an `OP_RETURN` MAP SET: its fields, string-valued.
    static func currentMap(_ script: Script) -> [String: JSONValue]? {
        guard let map = MAPTemplate.decode(script), map.command == "SET" else { return nil }
        var fields: [String: JSONValue] = [:]
        for (key, value) in map.data { fields[key] = .string(value) }
        return fields
    }

    /// `MapIndexer` tags: `name:` from MAP `name`, else `subTypeData.name`.
    static func mapNameTags(_ script: Script) -> [String] {
        guard let map = currentMap(script), let name = OrdinalTags.nameFromMap(map), !name.isEmpty
        else { return [] }
        return ["name:\(name)"]
    }

    /// `nameFromContent`: the trimmed UTF-8 body, first 64 UTF-16 units.
    static func opnsName(_ content: [UInt8]?) -> String? {
        guard let content else { return nil }
        let trimmed = String(decoding: content, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var units = Array(trimmed.utf16.prefix(64))
        if let last = units.last, UTF16.isLeadSurrogate(last) { units.removeLast() }
        let name = String(decoding: units, as: UTF16.self)
        return name.isEmpty ? nil : name
    }

    static func baseType(_ type: String?) -> String? {
        guard let type else { return nil }
        return type.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func insertion(
        vout: UInt32,
        basket: String,
        tags: [String],
        customInstructions: String
    ) throws -> WalletInternalizeOutput {
        WalletInternalizeOutput(
            outputIndex: vout,
            remittance: .basketInsertion(
                try WalletBasketInsertion(
                    basket: basket,
                    customInstructions: customInstructions,
                    tags: tags
                )
            )
        )
    }
}
