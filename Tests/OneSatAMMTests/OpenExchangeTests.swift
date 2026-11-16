import Foundation
import XCTest
import BSVCore
import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet
import ToolboxAuth
import ToolboxBRC29
import ToolboxStorage
import OneSatColor
@testable import OneSatAMM

private let TX = String(repeating: "ab", count: 16) + String(repeating: "cd", count: 16)
private let UP = TX.uppercased()

/// Vectors from skein-amm 0.55.1 (cc146be) web/ui/test/tokenId.test.ts.
final class AMMTokenIDTests: XCTestCase {
    func testEveryFormNamesTheSameToken() throws {
        XCTAssertEqual(AMMTokenID.parse(TX), try ColorAssetID(txid: TX, vout: 0))
        XCTAssertEqual(AMMTokenID.parse("\(TX)_0"), try ColorAssetID(txid: TX, vout: 0))
        XCTAssertEqual(AMMTokenID.parse("\(UP).0"), try ColorAssetID(txid: TX, vout: 0))
        XCTAssertEqual(AMMTokenID.parse("\(TX)_3"), try ColorAssetID(txid: TX, vout: 3))
        XCTAssertEqual(AMMTokenID.parse("\(TX).3"), try ColorAssetID(txid: TX, vout: 3))
        XCTAssertNil(AMMTokenID.parse("tm_color_" + TX))
        XCTAssertNil(AMMTokenID.parse(String(TX.dropFirst(2))))
        // Trimmed as `String.prototype.trim`; `\d+` read as `Number` (leading zeros, <= 0xffffffff).
        XCTAssertEqual(AMMTokenID.parse(" \(TX)_07\n"), try ColorAssetID(txid: TX, vout: 7))
        XCTAssertEqual(AMMTokenID.parse("\(TX)_4294967295")?.vout, UInt32.max)
        XCTAssertNil(AMMTokenID.parse("\(TX)_4294967296"))
        XCTAssertNil(AMMTokenID.parse("\(TX)_"))
        XCTAssertNil(AMMTokenID.parse("\(TX)-1"))
        XCTAssertNil(AMMTokenID.parse("\(TX)_1x"))
    }

    func testOutpointsNeedAVout() throws {
        XCTAssertEqual(AMMTokenID.parseOutpoint("\(TX)_1"), try ColorAssetID(txid: TX, vout: 1))
        XCTAssertNil(AMMTokenID.parseOutpoint(TX))
    }

    func testCanonicalIsTxidUnderscoreVout() throws {
        XCTAssertEqual(try AMMTokenID.canonical(TX), "\(TX)_0")
        XCTAssertEqual(try AMMTokenID.canonical("\(TX).3"), "\(TX)_3")
        XCTAssertEqual(try AMMTokenID.canonical("\(UP)_5"), "\(TX)_5")
        XCTAssertThrowsError(try AMMTokenID.canonical("nope")) { error in
            XCTAssertTrue((error as? OpenExchangeError)?.message.hasPrefix("not a token id") == true)
        }
        // The module's baskets name it by its tag, `p color <txid>v<vout>`.
        XCTAssertEqual(ColorIdentifiers.basket(try XCTUnwrap(AMMTokenID.parse(TX)), role: .value), "p color \(TX)v0")
    }
}

/// skein-amm test/client.test.ts "createClient (D9)": the bases.
final class OpenExchangeURLTests: XCTestCase {
    func testBases() throws {
        XCTAssertEqual(try OpenExchangeURLs.exchangeBase("https://swap.example"), "https://swap.example/amm")
        XCTAssertEqual(try OpenExchangeURLs.exchangeBase("https://swap.example/"), "https://swap.example/amm")
        XCTAssertEqual(try OpenExchangeURLs.exchangeBase("http://127.0.0.1:8100/@swap/amm/"), "http://127.0.0.1:8100/@swap/amm")
        XCTAssertEqual(try OpenExchangeURLs.exchangeBase("https://Swap.Example:443"), "https://swap.example/amm")
        let T = "\(String(repeating: "ab", count: 32))_0"
        let exchange = try OpenExchange(origin: "https://swap.example")
        XCTAssertEqual(exchange.base, "https://swap.example/amm")
        XCTAssertEqual(try exchange.tokenBase(T), "https://swap.example/@\(T)/amm")
        XCTAssertEqual(try exchange.discoveryBase(), "https://swap.example/@discovery/1color")
        XCTAssertEqual(try OpenExchangeURLs.discoveryBase(from: "http://127.0.0.1:8100/@swap/amm"), "http://127.0.0.1:8100/@discovery/1color")
        XCTAssertEqual(OpenExchangeURLs.instanceBase("https://swap.example/amm"), "https://swap.example")
        XCTAssertEqual(OpenExchangeURLs.instanceBase("http://127.0.0.1:8100/@swap/amm"), "http://127.0.0.1:8100/@swap")
        XCTAssertEqual(OpenExchangeURLs.instanceBase("http://127.0.0.1:8100/@swap"), "http://127.0.0.1:8100/@swap")
    }

    func testHandshakeGoesToThePrefixedInstance() async throws {
        let http = StubHTTP()
        let prefixed = InstanceTransport(instance: try XCTUnwrap(URL(string: "http://127.0.0.1:8100/@swap")), inner: http)
        _ = try await prefixed.send(HTTPRequest(method: "POST", url: try XCTUnwrap(URL(string: "http://127.0.0.1:8100/.well-known/auth"))))
        _ = try await prefixed.send(HTTPRequest(method: "POST", url: try XCTUnwrap(URL(string: "http://127.0.0.1:8100/@swap/amm/enable?x=1"))))
        let root = InstanceTransport(instance: try XCTUnwrap(URL(string: "https://swap.example")), inner: http)
        _ = try await root.send(HTTPRequest(method: "POST", url: try XCTUnwrap(URL(string: "https://swap.example/.well-known/auth"))))
        let urls = await http.urls
        XCTAssertEqual(urls, [
            "http://127.0.0.1:8100/@swap/.well-known/auth",
            "http://127.0.0.1:8100/@swap/amm/enable?x=1",
            "https://swap.example/.well-known/auth",
        ])
    }

    func testFormEncodingIsURLSearchParams() {
        XCTAssertEqual(OpenExchange.formComponent("a+b/c=="), "a%2Bb%2Fc%3D%3D")
        XCTAssertEqual(OpenExchange.formComponent("a b*-._~!'()"), "a+b*-._%7E%21%27%28%29")
        XCTAssertEqual(OpenExchange.uriComponent("a b~!'()*_"), "a%20b~!'()*_")
    }
}

final class OpenExchangeReadTests: XCTestCase {
    func testDefaults() async throws {
        let http = StubHTTP()
        await http.json("https://swap.example/amm/defaults", #"{"terms":{"lpFeeBps":30,"validatorFeeBps":5,"commissionBps":10,"minLegSats":0},"market":{"minCommissionBps":2},"enablePriceSats":1000}"#)
        let exchange = try OpenExchange(origin: "https://swap.example", http: http)
        let defaults = try await exchange.defaults()
        XCTAssertEqual(defaults.terms, .init(lpFeeBps: 30, validatorFeeBps: 5, commissionBps: 10, minLegSats: nil))
        XCTAssertEqual(defaults.market, .init(minCommissionBps: 2))
        XCTAssertEqual(defaults.enablePriceSats, 1000)
        let requests = await http.requests
        XCTAssertEqual(requests.map(\.method), ["GET"])
        XCTAssertEqual(requests.first?.headers["accept"], "application/json")

        await http.json("https://swap.example/amm/defaults", #"{"enablePriceSats":null}"#)
        let off = try await exchange.defaults()
        XCTAssertEqual(off, OpenExchangeDefaults(terms: nil, market: nil, enablePriceSats: nil))
        await http.json("https://swap.example/amm/defaults", #"{"terms":{"lpFeeBps":30,"validatorFeeBps":5},"enablePriceSats":0}"#)
        let partial = try await exchange.defaults()
        XCTAssertNil(partial.terms)
        XCTAssertNil(partial.enablePriceSats)
    }

    func testTokenListEveryStatusCanonicalIds() async throws {
        let http = StubHTTP()
        await http.json("https://swap.example/amm/tokens", """
        [{"tokenId":"\(TX).0","topic":"tm_color_\(TX)_0","sym":"TST","dec":2,"status":"enabled","since":5,"iconUrl":"/@discovery/1color/\(TX)_0/icon"},
         {"tokenId":"\(TX)_1","status":"disabled","icon":"data:x"},
         {"tokenId":"\(TX)_2","status":"pending"},
         {"status":"enabled"}]
        """)
        let exchange = try OpenExchange(origin: "https://swap.example", http: http)
        let tokens = try await exchange.tokens()
        XCTAssertEqual(tokens.map(\.tokenId), ["\(TX)_0", "\(TX)_1"])
        XCTAssertEqual(tokens[0].icon, "https://swap.example/@discovery/1color/\(TX)_0/icon")
        XCTAssertEqual(tokens[0].sym, "TST")
        XCTAssertEqual(tokens[0].dec, 2)
        XCTAssertEqual(tokens[0].since, 5)
        XCTAssertEqual(tokens[1].topic, "tm_color_\(TX)_1")
        XCTAssertEqual(tokens[1].sym, "")
        XCTAssertEqual(tokens[1].icon, "data:x")
        let enabled = try await exchange.enabledTokens()
        XCTAssertEqual(enabled.map(\.tokenId), ["\(TX)_0"])
    }

    func testExchangeIdentityFromWellKnownSkein() async throws {
        let key = "02" + String(repeating: "AB", count: 32)
        let http = StubHTTP()
        await http.json("https://swap.example/.well-known/skein", #"{"claimed":true,"identity":"\#(key)"}"#)
        let identity = try await OpenExchange(origin: "https://swap.example", http: http).exchangeIdentity()
        XCTAssertEqual(identity, key.lowercased())

        await http.json("http://127.0.0.1:8100/@swap/.well-known/skein", #"{"identity":"04ab"}"#)
        do {
            _ = try await OpenExchange(origin: "http://127.0.0.1:8100/@swap/amm", http: http).exchangeIdentity()
            XCTFail("an identity that is not a compressed key")
        } catch {
            XCTAssertEqual(error as? OpenExchangeError, .failed("GET http://127.0.0.1:8100/@swap/.well-known/skein: no identity"))
        }
    }

    func testDiscoveryDeploy() async throws {
        let http = StubHTTP()
        await http.route("https://swap.example/@discovery/1color/\(TX)_0/deploy", 200, [1, 2, 3])
        let exchange = try OpenExchange(origin: "https://swap.example", http: http)
        let found = try await exchange.discoveryDeployBeef("\(TX)_0")
        XCTAssertEqual(found, [1, 2, 3])
        let missing = try await exchange.discoveryDeployBeef("\(TX)_1")
        XCTAssertNil(missing)
        let accepts = await http.requests.map { $0.headers["accept"] }
        XCTAssertEqual(accepts, ["application/octet-stream", "application/octet-stream"])
    }

    func testANetworkFailureIsNetwork() async throws {
        struct Down: HTTPTransport {
            func send(_ request: HTTPRequest) async throws -> HTTPResponse { throw URLError(.notConnectedToInternet) }
        }
        do {
            _ = try await OpenExchange(origin: "https://swap.example", http: Down()).tokens()
            XCTFail("no answer")
        } catch let error as OpenExchangeError {
            guard case .network = error else { return XCTFail("\(error)") }
        }
    }
}

/// `enableTokenPaid` (client.ts:1957) against an in-memory BRC-177 wallet, a stubbed host and a
/// stubbed BRC-104 session.
final class OpenExchangeEnableTests: XCTestCase {
    let origin = "https://swap.example"
    let exchangeKey = try! PrivateKey([UInt8](repeating: 0, count: 31) + [0x0e])
    let identity = try! PrivateKey([UInt8](repeating: 0, count: 31) + [0x0a])
    var exchangeHex: String { Hex.encode(exchangeKey.publicKey.compressedBytes) }

    struct World {
        let storage: MemoryStorage
        let ctx: OneColorContext
        let http: StubHTTP
        let signed: StubSigned
        let log: SessionLog
        let exchange: OpenExchange
    }

    func world(price: String = "1000", answer: StubSigned.Answer? = nil) async throws -> World {
        let storage = try MemoryStorage(identity: identity)
        let ctx = OneColorContext(
            identity: identity, storage: storage,
            auth: AuthID(identityKey: Hex.encode(identity.publicKey.compressedBytes)), maximumFee: 20_000
        )
        let http = StubHTTP()
        await http.json("\(origin)/amm/defaults", #"{"enablePriceSats":\#(price)}"#)
        await http.json("\(origin)/.well-known/skein", #"{"claimed":true,"identity":"\#(exchangeHex)"}"#)
        let signed = StubSigned(answer ?? .response(200, #"{"fn":"enable","result":{"tokenId":"\#(TX)_0","topic":"tm_color_\#(TX)_0","sym":"TST","dec":2,"status":"enabled","since":7,"paidBy":"\#(Hex.encode(identity.publicKey.compressedBytes))","paymentTxid":"ff","satoshisPaid":1000}}"#))
        let log = SessionLog()
        let exchange = try OpenExchange(origin: origin, http: http) { identity, instance in
            log.record(identity, instance)
            return signed
        }
        return World(storage: storage, ctx: ctx, http: http, signed: signed, log: log, exchange: exchange)
    }

    /// The txid of the payment: the last transaction the wallet processed (as `noSend`).
    func paymentTxidOf(_ storage: MemoryStorage) async throws -> String {
        let processed = await storage.processed
        let raw = try XCTUnwrap(processed.last?.rawTX)
        return try Transaction(bytes: raw, limits: txLimits).transactionID(limits: txLimits).displayHex
    }

    func txids(_ beef: [UInt8]) throws -> Set<String> {
        let parsed = try BEEF(bytes: beef, limits: beefLimits)
        return Set(try parsed.transactions.map { try $0.transactionID(limits: txLimits).displayHex })
    }

    func testEnablePaidSendsExactlyWhatTheClientSends() async throws {
        let w = try await world()
        let deploy = try deployTransaction()
        let deployID = try deploy.transactionID(limits: txLimits).displayHex
        let listing = try await w.exchange.enablePaid(w.ctx, tokenId: "\(UP).0", deployBeef: try atomicBytes(deploy))

        // The payment's createAction.
        let targets = await w.storage.targets
        let request = try XCTUnwrap(targets.first)
        XCTAssertEqual(targets.count, 1)
        XCTAssertEqual(request.description, "Open Exchange: enable a token")
        XCTAssertEqual(request.labels, ["p nosend expiry seconds 600"])
        XCTAssertEqual(request.options?.noSend, true)
        XCTAssertEqual(request.options?.randomizeOutputs, false)
        XCTAssertNil(request.options?.signAndProcess)
        XCTAssertNil(request.inputs)
        let output = try XCTUnwrap(request.outputs?.first)
        XCTAssertEqual(request.outputs?.count, 1)
        XCTAssertEqual(output.satoshis, 1000)
        XCTAssertEqual(output.outputDescription, "Open Exchange enable fee")
        XCTAssertNil(output.basket)
        XCTAssertEqual(output.tags, [])

        // The signed POST.
        let sent = await w.signed.sent
        let post = try XCTUnwrap(sent.first)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(w.log.instances, ["https://swap.example"])
        XCTAssertEqual(w.log.identities, [Hex.encode(identity.publicKey.compressedBytes)])
        XCTAssertEqual(post.method, "POST")
        XCTAssertEqual(post.path, "/amm/enable")
        XCTAssertEqual(post.headers, ["content-type": "application/octet-stream"])

        // The derivation the payment, its instructions and the query share.
        let instructions = try XCTUnwrap(output.customInstructions)
        let parts = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(instructions.utf8)) as? [String: String])
        let prefix = try XCTUnwrap(parts["derivationPrefix"])
        let suffix = try XCTUnwrap(parts["derivationSuffix"])
        XCTAssertEqual(
            instructions,
            #"{"derivationPrefix":"\#(prefix)","derivationSuffix":"\#(suffix)","payee":"\#(exchangeHex)"}"#
        )
        let paymentTxid = try await paymentTxidOf(w.storage)
        XCTAssertEqual(
            post.query,
            "?tokenId=\(TX)_0&paymentTxid=\(paymentTxid)&paymentVout=0&derivationPrefix=\(OpenExchange.formComponent(prefix))&derivationSuffix=\(OpenExchange.formComponent(suffix))"
        )

        // The payee key: BRC-29 from this wallet to the exchange, as the exchange derives it.
        let payee = try BRC29.payingPublicKey(recipient: exchangeKey.publicKey, sender: identity, prefix: prefix, suffix: suffix)
        XCTAssertEqual(output.lockingScript, try BRC29.lockingScript(for: payee).bytes)
        let exchangeSide = try BRC29.receivingPrivateKey(recipient: exchangeKey, sender: identity.publicKey, prefix: prefix, suffix: suffix)
        XCTAssertEqual(exchangeSide.publicKey.compressedBytes, payee.compressedBytes)

        // Each derivation half is a `createNonce(wallet, "self")`: 16 bytes and their HMAC.
        let wallet = ProtoWallet(rootKey: identity)
        for nonce in [prefix, suffix] {
            let bytes = try XCTUnwrap(Data(base64Encoded: nonce)).map { $0 }
            XCTAssertEqual(bytes.count, 48)
            let first = Array(bytes[..<16])
            let verified = try await wallet.verifyHMAC(WalletVerifyHMACRequest(
                protocolID: try WalletProtocolID(securityLevel: .everyAppAndCounterparty, name: "server hmac"),
                keyID: try WalletKeyID(String(decoding: first, as: UTF8.self)), counterparty: .self,
                data: first, hmac: try WalletHMAC(bytes: Array(bytes[16...]))
            ))
            XCTAssertTrue(verified.valid)
        }
        XCTAssertNotEqual(prefix, suffix)

        // One V2 BEEF with the deploy and the payment, which pays the price at output 0.
        let body = try XCTUnwrap(post.body)
        XCTAssertEqual(Array(body.prefix(4)), [0x02, 0x00, 0xbe, 0xef])
        let inBody = try txids(body)
        XCTAssertTrue(inBody.contains(deployID))
        XCTAssertTrue(inBody.contains(paymentTxid))
        let parsed = try BEEF(bytes: body, limits: beefLimits)
        let payment = try XCTUnwrap(try parsed.transaction(for: try TransactionID(displayHex: paymentTxid), limits: txLimits))
        XCTAssertEqual(payment.outputs.count, 1)
        XCTAssertEqual(payment.outputs[0].satoshis, 1000)
        XCTAssertEqual(payment.outputs[0].lockingScript.bytes, output.lockingScript)

        // Built and signed as noSend, never broadcast; nothing aborted.
        let processed = await w.storage.processed
        XCTAssertEqual(processed.last?.isNoSend, true)
        let aborted = await w.storage.aborted
        XCTAssertEqual(aborted, [])

        // The fresh price read, the exchange's identity, and no discovery read (the deploy was given).
        let urls = await w.http.urls
        XCTAssertEqual(urls, ["https://swap.example/amm/defaults", "https://swap.example/.well-known/skein"])

        XCTAssertEqual(listing.token?.tokenId, "\(TX)_0")
        XCTAssertEqual(listing.token?.status, .enabled)
        XCTAssertEqual(listing.paymentTxid, "ff")
        XCTAssertEqual(listing.satoshisPaid, 1000)
        XCTAssertEqual(listing.paidBy, Hex.encode(identity.publicKey.compressedBytes))
    }

    func testTheDeployComesFromTheWalletThenDiscovery() async throws {
        let w = try await world()
        let deploy = try deployTransaction(2)
        let deployID = try deploy.transactionID(limits: txLimits).displayHex
        let assetID = try ColorAssetID(txid: deployID, vout: 0)
        try await w.storage.hold(deploy, vout: 0, basket: ColorIdentifiers.basket(assetID, role: .authority))

        let held = try await OpenExchange.walletDeployBeef(w.ctx, tokenId: deployID)
        let atomic = try AtomicBEEF(bytes: try XCTUnwrap(held), limits: beefLimits)
        XCTAssertEqual(atomic.subjectTransactionID.displayHex, deployID)
        let listed = await w.storage.listed
        XCTAssertEqual(listed.map(\.basket), ["p color \(deployID)v0", "p color \(deployID)v0 authority"])
        XCTAssertEqual(listed.map(\.include), [.entireTransactions, .entireTransactions])
        XCTAssertEqual(listed.map { $0.pagination.effectiveLimit }, [100, 100])

        _ = try await w.exchange.enablePaid(w.ctx, tokenId: deployID)
        let firstSent = await w.signed.sent.first
        let body = try XCTUnwrap(firstSent?.body)
        XCTAssertTrue(try txids(body).contains(deployID))
        let urls = await w.http.urls
        XCTAssertFalse(urls.contains { $0.contains("@discovery") })

        // Not in the wallet: discovery's, by its canonical id.
        let other = try await world()
        let discovered = try deployTransaction(3)
        let discoveredID = try discovered.transactionID(limits: txLimits).displayHex
        await other.http.route("\(origin)/@discovery/1color/\(discoveredID)_0/deploy", 200, try atomicBytes(discovered))
        _ = try await other.exchange.enablePaid(other.ctx, tokenId: discoveredID)
        let otherSent = await other.signed.sent.first
        XCTAssertTrue(try txids(try XCTUnwrap(otherSent?.body)).contains(discoveredID))
        let discoveryRead = await other.http.requests.last
        XCTAssertEqual(discoveryRead?.url.absoluteString, "\(origin)/@discovery/1color/\(discoveredID)_0/deploy")
        XCTAssertEqual(discoveryRead?.headers, [:])

        // Neither: refused before any payment.
        let none = try await world()
        do {
            _ = try await none.exchange.enablePaid(none.ctx, tokenId: "\(TX)_4")
            XCTFail("no deploy anywhere")
        } catch {
            XCTAssertEqual(error as? OpenExchangeError, .refused(code: nil, message: "no deploy for \(TX)_4 on discovery (404): pass deployBeef"))
        }
        let targets = await none.storage.targets
        XCTAssertEqual(targets.count, 0)
    }

    func testPaidEnableOffIsRefusedBeforeAnything() async throws {
        let w = try await world(price: "null")
        do {
            _ = try await w.exchange.enablePaid(w.ctx, tokenId: TX, deployBeef: try atomicBytes(try deployTransaction()))
            XCTFail("paid enable is off")
        } catch {
            XCTAssertEqual(error as? OpenExchangeError, .refused(code: nil, message: "paid enable is off"))
        }
        let targets = await w.storage.targets
        let sent = await w.signed.sent
        XCTAssertEqual(targets.count, 0)
        XCTAssertEqual(sent.count, 0)
    }

    func testARefusalAbortsThePayment() async throws {
        let cases: [(StubSigned.Answer, OpenExchangeError, OpenExchangeRefusal?)] = [
            (.response(409, #"{"status":"error","code":"ERR_TOKEN_ENABLED","description":"the token is enabled already"}"#),
             .refused(code: "ERR_TOKEN_ENABLED", message: "ERR_TOKEN_ENABLED: the token is enabled already"), .tokenEnabled),
            (.response(402, #"{"status":"error","code":"ERR_PAYMENT_TOO_SMALL","satoshisRequired":2000,"description":"the payment output holds 1000 sats; the price is 2000"}"#),
             .refused(code: "ERR_PAYMENT_TOO_SMALL", message: "ERR_PAYMENT_TOO_SMALL: the payment output holds 1000 sats; the price is 2000"), .paymentTooSmall),
            (.response(402, ""),
             .refused(code: "ERR_PAYMENT_REQUIRED", message: "ERR_PAYMENT_REQUIRED: the exchange did not take this payment (402; its price may have changed)"), .paymentRequired),
            (.response(400, #"{"code":"ERR_INVALID_PAYMENT","message":"bad key"}"#),
             .refused(code: "ERR_INVALID_PAYMENT", message: "ERR_INVALID_PAYMENT: bad key"), .invalidPayment),
            (.response(500, "oops"), .refused(code: nil, message: "500: refused"), nil),
            (.error(AuthTransportError.unauthenticatedReply(status: 403, body: Array(#"{"code":"ERR_PAID_ENABLE_OFF","description":"paid enable is off: this exchange sets no price to enable a token"}"#.utf8))),
             .refused(code: "ERR_PAID_ENABLE_OFF", message: "ERR_PAID_ENABLE_OFF: paid enable is off: this exchange sets no price to enable a token"), .paidEnableOff),
            (.error(URLError(.timedOut)), .network(OpenExchangeError.errorText(URLError(.timedOut))), nil),
            (.error(AuthTransportError.transportFailed("down")), .network(OpenExchangeError.errorText(AuthTransportError.transportFailed("down"))), nil),
        ]
        for (answer, expected, refusal) in cases {
            let w = try await world(answer: answer)
            do {
                _ = try await w.exchange.enablePaid(w.ctx, tokenId: TX, deployBeef: try atomicBytes(try deployTransaction()))
                XCTFail("refused: \(expected)")
            } catch {
                XCTAssertEqual(error as? OpenExchangeError, expected)
                XCTAssertEqual((error as? OpenExchangeError)?.refusal, refusal)
            }
            let paymentTxid = try await paymentTxidOf(w.storage)
            let aborted = await w.storage.aborted
            XCTAssertEqual(aborted, [paymentTxid], "\(expected)")
        }
    }

    func testAWalletWithoutBRC177IsRefusedAndNothingIsSent() async throws {
        let w = try await world()
        await w.storage.setNoSendSupported(false)
        do {
            _ = try await w.exchange.enablePaid(w.ctx, tokenId: TX, deployBeef: try atomicBytes(try deployTransaction()))
            XCTFail("no BRC-177")
        } catch let error as OpenExchangeError {
            guard case .refused(nil, let message) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(message.hasPrefix("the wallet could not build the protected payment (BRC-177 noSend): "), message)
        }
        let sent = await w.signed.sent
        let aborted = await w.storage.aborted
        XCTAssertEqual(sent.count, 0)
        XCTAssertEqual(aborted, [])
    }

    func testTheDefaultSessionShakesHandsAtTheInstanceAsTheWallet() async throws {
        let storage = try MemoryStorage(identity: identity)
        let ctx = OneColorContext(
            identity: identity, storage: storage,
            auth: AuthID(identityKey: Hex.encode(identity.publicKey.compressedBytes)), maximumFee: 20_000
        )
        let dev = "http://127.0.0.1:8100/@swap"
        let http = StubHTTP()
        await http.json("\(dev)/amm/defaults", #"{"enablePriceSats":500}"#)
        await http.json("\(dev)/.well-known/skein", #"{"identity":"\#(exchangeHex)"}"#)
        let exchange = try OpenExchange(origin: "\(dev)/amm", http: http)
        do {
            _ = try await exchange.enablePaid(ctx, tokenId: TX, deployBeef: try atomicBytes(try deployTransaction()))
            XCTFail("the stub host shakes no hands")
        } catch let error as OpenExchangeError {
            guard case .failed = error else { return XCTFail("\(error)") }
        }
        let requests = await http.requests
        XCTAssertEqual(requests.map(\.url.absoluteString), [
            "\(dev)/amm/defaults", "\(dev)/.well-known/skein", "\(dev)/.well-known/auth",
        ])
        XCTAssertEqual(requests.last?.method, "POST")
        let handshake = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(requests.last?.body))) as? [String: Any])
        XCTAssertEqual(handshake["identityKey"] as? String, Hex.encode(identity.publicKey.compressedBytes))
        let aborted = await storage.aborted
        let paymentTxid = try await paymentTxidOf(storage)
        XCTAssertEqual(aborted, [paymentTxid])
    }

    func testErrorKinds() {
        XCTAssertEqual(OpenExchangeRefusal.allCases.map(\.rawValue), [
            "ERR_PAID_ENABLE_OFF", "ERR_BAD_REQUEST", "ERR_BAD_DEPLOY", "ERR_BEEF", "ERR_INVALID_PAYMENT",
            "ERR_TOKEN_ENABLED", "ERR_TOKEN_DISABLED", "ERR_PAYMENT_REPLAYED", "ERR_PAYMENT_REQUIRED", "ERR_PAYMENT_TOO_SMALL",
        ])
        XCTAssertEqual(OpenExchangeError.kinded(TestError("The user has denied the request for permission.")),
                       .userRejected("The user has denied the request for permission."))
        XCTAssertEqual(OpenExchangeError.kinded(TestError("ERR_PERMISSION_DENIED: no")), .userRejected("ERR_PERMISSION_DENIED: no"))
        XCTAssertNil(OpenExchangeError.kinded(TestError("Connect a wallet first")))
        XCTAssertEqual(OpenExchangeError.of(TestError("Connect a wallet first")), .failed("Connect a wallet first"))
        XCTAssertEqual(OpenExchangeError.refused(code: "ERR_BEEF", message: "ERR_BEEF: x").refusal, .beef)
    }
}
