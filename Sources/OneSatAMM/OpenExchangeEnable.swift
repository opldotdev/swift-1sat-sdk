import Foundation
import BSVCore
import BSVKeys
import BSVTransaction
import BSVWallet
import ToolboxActions
import ToolboxAuth
import ToolboxBRC29
import ToolboxStorage
import OneSatColor
import OneSatTemplates

/// Paid listing ("enable") on Open Exchange: `enableTokenPaid` and `walletDeployBeef` of
/// `@dcasegr/amm-client` 0.55.1 (skein-amm cc146be, client.ts), against the wallet the 1Color
/// actions use (`OneColorContext`: identity key, storage, BRC-177 protected `noSend`).
extension OpenExchange {
    /// `ENABLE_PAYMENT_EXPIRY_LABEL` (client.ts:586): the payment is a protected `noSend`
    /// (BRC-177) the wallet reclaims if nobody sends it within 600 s.
    public static let enablePaymentExpiryLabel = "p nosend expiry seconds 600"
    /// The payment action's description (client.ts:1975).
    public static let enableActionDescription = "Open Exchange: enable a token"
    /// The payment output's description (client.ts:1976).
    public static let enableOutputDescription = "Open Exchange enable fee"
    /// `BRC29_PROTOCOL` (wallet/brc29.ts:31): `[2, "3241645161d8"]`.
    static func brc29Protocol() throws -> WalletProtocolID {
        try WalletProtocolID(securityLevel: .everyAppAndCounterparty, name: BRC29.protocolID)
    }

    /// `walletDeployBeef` (client.ts:559): the token's deploy from the wallet, as an Atomic BEEF
    /// of the deploy transaction. The deploy output in its value basket `p color <txid>v<vout>`,
    /// then its authority basket, listed with `include: "entire transactions"`, limit 100. Nil
    /// when the wallet holds it in neither (not the deployer's, or the output spent).
    public static func walletDeployBeef(_ ctx: OneColorContext, tokenId: String) async throws -> [UInt8]? {
        do {
            guard let id = AMMTokenID.parse(try AMMTokenID.canonical(tokenId)) else {
                throw OpenExchangeError.failed("not a token id: \(tokenId)")
            }
            for role in [ColorTokenRole.value, .authority] {
                let page = try await ctx.storage.colorListOutputs(ctx.auth, try WalletListOutputsRequest(
                    basket: ColorIdentifiers.basket(id, role: role), include: .entireTransactions,
                    pagination: try WalletPagination(limit: 100)
                ))
                let held = page.outputs.contains { $0.outpoint.description == id.outpoint }
                guard held, let beef = page.beef, !beef.transactions.isEmpty else { continue }
                let atomic = try ColorBEEF.atomic(try TransactionID(displayHex: id.txid), in: beef)
                return try atomic.serialized(limits: beefLimits)
            }
            return nil
        } catch {
            throw OpenExchangeError.of(error)
        }
    }

    /// `enableTokenPaid` (client.ts:1957): enables `tokenId` on the exchange for its fee.
    ///
    /// 1. The price, read fresh from `GET <swap>/defaults` (`enablePriceSats`); none is refused,
    ///    "paid enable is off".
    /// 2. The exchange's identity, `GET <instance>/.well-known/skein`.
    /// 3. The deploy's BEEF: `deployBeef` as given, else the wallet's (`walletDeployBeef`, as the
    ///    1sat-amm app's `payToList` passes it), else discovery's `GET <discovery>/<id>/deploy`.
    /// 4. The payment, BRC-29 to the exchange: two `createNonce` values, the payee key
    ///    `[2, "3241645161d8"]` / `"<prefix> <suffix>"` / counterparty the exchange, one P2PKH
    ///    output of exactly the price, built and signed as a BRC-177 protected `noSend` (not sent:
    ///    the exchange sends it).
    /// 5. One BEEF holding the deploy and the payment, BRC-104 signed `POST <swap>/enable?tokenId=
    ///    &paymentTxid=&paymentVout=0&derivationPrefix=&derivationSuffix=`.
    ///
    /// On any failure after the payment was built, the payment is aborted in the wallet
    /// (`abortAction` by its txid), so its coins are free again. Returns the enabled row.
    ///
    /// `expectedPriceSats` is the fee the person agreed to. When given, a different price on the
    /// fresh read refuses before any payment is built, as the 1sat-amm `ListingStep` re-reads the
    /// fee before paying.
    public func enablePaid(
        _ ctx: OneColorContext, tokenId: String, deployBeef: [UInt8]? = nil,
        expectedPriceSats: Int? = nil
    ) async throws -> OpenExchangeListing {
        do {
            return try await enablePaidUnguarded(
                ctx, tokenId: tokenId, deployBeef: deployBeef, expectedPriceSats: expectedPriceSats
            )
        } catch {
            throw OpenExchangeError.of(error)
        }
    }

    private func enablePaidUnguarded(
        _ ctx: OneColorContext, tokenId: String, deployBeef: [UInt8]?, expectedPriceSats: Int?
    ) async throws -> OpenExchangeListing {
        let canonical = try AMMTokenID.canonical(tokenId)
        guard let price = try await defaults().enablePriceSats else {
            throw OpenExchangeError.refused(code: nil, message: "paid enable is off")
        }
        if let expectedPriceSats, expectedPriceSats != price {
            throw OpenExchangeError.refused(
                code: nil,
                message: "the listing fee changed from \(expectedPriceSats) to \(price) sats; review it before paying"
            )
        }
        let exchange = try await exchangeIdentity()
        let deploy: [UInt8]
        if let deployBeef {
            deploy = deployBeef
        } else if let held = try await Self.walletDeployBeef(ctx, tokenId: canonical) {
            deploy = held
        } else {
            let url = "\(try discoveryBase())/\(canonical)/deploy"
            let response = try await get(url, accept: nil)
            guard (200..<300).contains(response.statusCode) else {
                throw OpenExchangeError.refused(
                    code: nil, message: "no deploy for \(canonical) on discovery (\(response.statusCode)): pass deployBeef"
                )
            }
            deploy = response.body
        }

        let wallet = ProtoWallet(rootKey: ctx.identity)
        let derivationPrefix = try await Self.createNonce(wallet)
        let derivationSuffix = try await Self.createNonce(wallet)
        let payee = try await wallet.getPublicKey(WalletGetPublicKeyRequest(selection: .derived(
            protocolID: try Self.brc29Protocol(),
            keyID: try WalletKeyID(BRC29.keyID(prefix: derivationPrefix, suffix: derivationSuffix)),
            counterparty: .publicKey(try PublicKey(try Hex.decode(exchange, maximumDecodedByteCount: 33))),
            forSelf: false
        ))).publicKey
        let request = try Self.enablePaymentRequest(
            priceSats: price, payee: payee, exchange: exchange,
            derivationPrefix: derivationPrefix, derivationSuffix: derivationSuffix
        )

        let built: NoSendExpiryAction.Result
        do {
            built = try await NoSendExpiryAction.run(
                storage: ctx.storage, auth: ctx.auth, identity: ctx.identity, request: request,
                maximumFee: ctx.maximumFee, signCallerInputs: { _, _ in [:] }
            )
        } catch {
            // No fallback to a plain noSend: a wallet that cannot make a protected one says why.
            throw OpenExchangeError.kinded(error) ?? OpenExchangeError.refused(
                code: nil,
                message: "the wallet could not build the protected payment (BRC-177 noSend): \(OpenExchangeError.errorText(error))"
            )
        }
        let txid = built.signed.transactionID.displayHex
        do {
            let body = try Self.mergeBEEF(deploy, try built.signed.atomicBEEF())
            let query = Self.enableQuery(
                tokenId: canonical, paymentTxid: txid,
                derivationPrefix: derivationPrefix, derivationSuffix: derivationSuffix
            )
            let instance = OpenExchangeURLs.instanceBase(base)
            guard let instanceURL = URL(string: instance) else { throw OpenExchangeError.failed("Invalid URL: \(instance)") }
            let path = OpenExchangeURLs.trimTrailingSlashes(try WebURL(base).pathname) + "/enable"
            let status: Int
            let answer: [UInt8]
            do {
                let response = try await session(ctx.identity, instanceURL).send(
                    method: "POST", path: path, query: "?" + query,
                    headers: ["content-type": "application/octet-stream"], body: body
                )
                (status, answer) = (response.statusCode, response.body)
            } catch AuthTransportError.unauthenticatedReply(let replyStatus, let replyBody) {
                // A refusal from in front of the instance's auth: its status and body, unsigned.
                (status, answer) = (replyStatus, replyBody)
            }
            let value = JSONValue.parse(answer)
            guard status == 200 else { throw Self.refusal(status: status, answer: value) }
            return OpenExchangeListing.read(value?["result"], listURL: "\(base)/tokens")
        } catch {
            await Self.abort(ctx, txid: txid)
            throw error
        }
    }

    // MARK: - The parts, as sent

    /// The payment's `createAction` (client.ts:1974): one P2PKH output of exactly the price to
    /// the payee key, its `customInstructions` `JSON.stringify({derivationPrefix,
    /// derivationSuffix, payee})`, the BRC-177 label, `{noSend: true, randomizeOutputs: false}`.
    static func enablePaymentRequest(
        priceSats: UInt64, payee: PublicKey, exchange: String, derivationPrefix: String, derivationSuffix: String
    ) throws -> WalletCreateActionRequest {
        try WalletCreateActionRequest(
            description: enableActionDescription,
            outputs: [try WalletCreateActionOutput(
                lockingScript: try BRC29.lockingScript(for: payee).bytes,
                satoshis: priceSats,
                outputDescription: enableOutputDescription,
                customInstructions: enableCustomInstructions(
                    derivationPrefix: derivationPrefix, derivationSuffix: derivationSuffix, payee: exchange
                )
            )],
            labels: [enablePaymentExpiryLabel],
            options: try WalletCreateActionOptions(noSend: true, randomizeOutputs: false)
        )
    }

    /// `JSON.stringify({ derivationPrefix, derivationSuffix, payee })`, in that key order.
    static func enableCustomInstructions(derivationPrefix: String, derivationSuffix: String, payee: String) -> String {
        "{\"derivationPrefix\":\(JSONText.quote(derivationPrefix)),\"derivationSuffix\":\(JSONText.quote(derivationSuffix)),\"payee\":\(JSONText.quote(payee))}"
    }

    /// `new URLSearchParams({tokenId, paymentTxid, paymentVout: "0", derivationPrefix,
    /// derivationSuffix}).toString()` (client.ts:1991), without the `?`.
    static func enableQuery(tokenId: String, paymentTxid: String, derivationPrefix: String, derivationSuffix: String) -> String {
        [
            ("tokenId", tokenId), ("paymentTxid", paymentTxid), ("paymentVout", "0"),
            ("derivationPrefix", derivationPrefix), ("derivationSuffix", derivationSuffix),
        ].map { "\(formComponent($0.0))=\(formComponent($0.1))" }.joined(separator: "&")
    }

    /// `new Beef(); b.mergeBeef(deploy); b.mergeBeef(created.tx); b.toBinary()` (client.ts:1988):
    /// one BRC-96 (V2) BEEF, the deploy's transactions first. Each part may be a BEEF or an
    /// Atomic BEEF.
    static func mergeBEEF(_ deploy: [UInt8], _ payment: [UInt8]) throws -> [UInt8] {
        var merged = try BEEF(version: .v2, merklePaths: [], transactions: [], limits: beefLimits)
        for part in [deploy, payment] {
            merged = try merged.merging(try readBEEF(part), limits: beefLimits)
        }
        return try merged.serialized(limits: beefLimits)
    }

    /// `Beef.fromBinary`: an Atomic BEEF's inner BEEF, or a BEEF, in any transaction order as
    /// that reader accepts it.
    static func readBEEF(_ bytes: [UInt8]) throws -> BEEF {
        if let atomic = try? AtomicBEEF(bytes: bytes, limits: beefLimits, transactionOrder: .any) {
            return atomic.beef
        }
        return try BEEF(bytes: bytes, limits: beefLimits, transactionOrder: .any)
    }

    /// `createNonce(wallet, "self")` of `@bsv/sdk`: 16 random bytes, then their HMAC under
    /// `[2, "server hmac"]` with the bytes as UTF-8 for the key ID, base64.
    static func createNonce(_ wallet: ProtoWallet) async throws -> String {
        var generator = SystemRandomNumberGenerator()
        let random = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        let hmac = try await wallet.createHMAC(WalletCreateHMACRequest(
            protocolID: try WalletProtocolID(securityLevel: .everyAppAndCounterparty, name: "server hmac"),
            keyID: try WalletKeyID(String(decoding: random, as: UTF8.self)),
            counterparty: .self,
            data: random
        ))
        return Data(random + hmac.hmac.bytes).base64EncodedString()
    }

    /// A non-200 answer to the enable (client.ts:2001): `"<code ?? status>: <description ??
    /// message ?? "refused">"`. A 402 with no code of its own is `ERR_PAYMENT_REQUIRED`, as TS
    /// reports the 402 its `AuthFetch` throws on.
    static func refusal(status: Int, answer: JSONValue?) -> OpenExchangeError {
        func given(_ key: String) -> String? {
            guard let value = answer?[key], value != .null else { return nil }
            return value.text
        }
        var code = given("code")
        var description = given("description") ?? given("message")
        if status == 402, code == nil {
            code = OpenExchangeRefusal.paymentRequired.rawValue
            description = description ?? "the exchange did not take this payment (402; its price may have changed)"
        }
        return .refused(code: code, message: "\(code ?? String(status)): \(description ?? "refused")")
    }

    /// `wallet.abortAction({reference: txid})`; its failure is ignored.
    ///
    /// It runs in a task of its own because the caller's task may be the one that was cancelled:
    /// a storage call made from it would throw at once and leave the coins reserved until the
    /// BRC-177 reclaim. An unstructured task does not inherit that cancellation.
    static func abort(_ ctx: OneColorContext, txid: String) async {
        guard let reference = try? WalletBase64Data(base64: txid) else { return }
        await Task {
            _ = try? await ctx.storage.abortAction(ctx.auth, WalletAbortActionRequest(reference: reference))
        }.value
    }

    static let beefLimits = WalletBEEFLimits.standard
}
