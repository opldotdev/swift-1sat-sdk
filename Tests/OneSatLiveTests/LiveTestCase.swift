import BSVTransaction
import BSVWallet
import Foundation
import ToolboxWallet
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The base of every live flow: skips without `ONESAT_LIVE`, installs the host guard, runs the
/// preflight once, and after each test checks that the run touched only the backend's hosts.
class LiveTestCase: XCTestCase {
    private(set) var backend: Backend!
    /// When the test began, for reading the local stack's call log from here on.
    private(set) var startedAt = Date()
    /// Requests HostGuard had seen to storage when the test began.
    private var storageSeenAtStart = 0

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        let backend = try Backend.current()
        HostGuard.install(allowedHosts: backend.allowedHosts)
        _ = try await Preflight.shared.check(backend)
        self.backend = backend
        storageSeenAtStart = HostGuard.hostsSeen[backend.storage.host?.lowercased() ?? ""] ?? 0
        startedAt = Date()
    }

    override func tearDown() async throws {
        if let backend {
            let refused = HostGuard.refusedRequests
            XCTAssertTrue(
                refused.isEmpty,
                "a \(backend.kind.rawValue) run contacted hosts outside \(backend.allowedHosts.sorted()): \(refused)"
            )
            let seen = HostGuard.hostsSeen
            let strays = Set(seen.keys).subtracting(backend.allowedHosts)
            XCTAssertTrue(strays.isEmpty, "requests went to hosts outside the allowlist: \(strays.sorted())")
            // The guard must see this test's own traffic, or its silence proves nothing (the
            // preflight's requests are counted before setUp's snapshot). A test that failed before
            // reaching storage has already said why.
            if testRun?.hasSucceeded == true {
                let storageSeen = seen[backend.storage.host?.lowercased() ?? ""] ?? 0
                XCTAssertGreaterThan(
                    storageSeen, storageSeenAtStart,
                    "HostGuard saw none of this test's requests to storage \(backend.storage.absoluteString); hosts seen: \(seen)"
                )
            }
            print("HOSTS \(seen.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        }
        try await super.tearDown()
    }

    func qa(_ role: QAWallets.Role) async throws -> LiveWallet {
        try await QASuite.shared.wallet(role, backend: backend)
    }

    /// A funded A, and the T that funds it.
    func fundedA() async throws -> LiveWallet {
        let a = try await qa(.A)
        let t = try await qa(.T)
        try await Funding.ensureFunded(a, treasury: t)
        return a
    }

    func assertTxid(_ txid: String?, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let txid else {
            XCTFail("\(what): no txid", file: file, line: line)
            return
        }
        XCTAssertEqual(txid.count, 64, "\(what): txid \(txid)", file: file, line: line)
        XCTAssertTrue(txid.allSatisfy(\.isHexDigit), "\(what): txid \(txid)", file: file, line: line)
    }

    // MARK: Local stack

    /// The local stack's record of storage calls by `identityHex` since this test began.
    func localCalls(for identityHex: String) async throws -> [StackCall] {
        precondition(backend.kind == .local)
        var components = URLComponents(
            url: backend.services.appendingPathComponent("__stack").appendingPathComponent("calls"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "identityKey", value: identityHex)]
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601WithFractions
        let since = startedAt.addingTimeInterval(-1)
        return try decoder.decode([StackCall].self, from: data).filter { $0.at >= since }
    }

    /// Txids the local stack's stub chain was asked to broadcast.
    func localBroadcasts() async throws -> [String] {
        precondition(backend.kind == .local)
        let url = backend.services.appendingPathComponent("__stack").appendingPathComponent("broadcasts")
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode([String].self, from: data)
    }

    /// Every storage call within the auth middleware's limits and answered without error.
    func assertCallsWithinLimits(_ calls: [StackCall], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(calls.isEmpty, "the local stack recorded no calls", file: file, line: line)
        for call in calls {
            XCTAssertLessThan(call.status, 400, "\(call.rpc) answered \(call.status): \(call.errorBody ?? "")", file: file, line: line)
            XCTAssertLessThan(call.jsonNodes, 100_000, "\(call.rpc) sent \(call.jsonNodes) JSON values", file: file, line: line)
            XCTAssertLessThan(call.longestArray, 100_000, "\(call.rpc) sent an array of \(call.longestArray)", file: file, line: line)
            if call.httpMethod == "POST", call.path == "/", call.status < 400 {
                XCTAssertTrue(call.signed, "\(call.rpc) answer was not signed", file: file, line: line)
            }
        }
    }

    func printCalls(_ calls: [StackCall]) {
        for call in calls {
            print("CALL \(call.rpc) reqBytes=\(call.reqBytes) jsonNodes=\(call.jsonNodes) longestArray=\(call.longestArray) "
                + "binReq=\(call.binaryRequestEncoding ?? "-") -> \(call.status) signed=\(call.signed)")
        }
    }
}

/// One line of the local stack's call log (`GET /__stack/calls`).
struct StackCall: Decodable, Sendable {
    let at: Date
    let identityKey: String?
    let httpMethod: String
    let path: String
    let rpc: String
    let reqBytes: Int
    let jsonNodes: Int
    let longestArray: Int
    let binaryRequestEncoding: String?
    let binaryEncodingAsked: String?
    let binaryEncodingEchoed: String?
    let status: Int
    let signed: Bool
    let resBytes: Int
    let resLongestArray: Int
    let errorBody: String?
}

extension JSONDecoder.DateDecodingStrategy {
    /// `Date.toISOString()`: ISO 8601 with milliseconds.
    static let iso8601WithFractions = custom { decoder in
        let text = try decoder.singleValueContainer().decode(String.self)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not an ISO 8601 date: \(text)"))
        }
        return date
    }
}

extension LiveWallet {
    /// Every output in `basket`, read page by page.
    func outputs(in basket: String, include: WalletOutputInclude? = nil) async throws -> [WalletOutput] {
        var all: [WalletOutput] = []
        var offset: UInt32 = 0
        while true {
            let page = try await wallet.listOutputs(try WalletListOutputsRequest(
                basket: basket,
                include: include,
                includeTags: true,
                pagination: try WalletPagination(limit: 1_000, offset: offset)
            ))
            all += page.outputs
            offset += UInt32(page.outputs.count)
            if page.outputs.isEmpty || offset >= page.totalOutputs { return all }
        }
    }

    /// The output of `txid` in `basket`, with its locking script. Lists the basket without scripts
    /// to find it, then reads that one output with its script, so the reply stays one output's
    /// size however large the basket grows.
    func output(of txid: String, in basket: String) async throws -> WalletOutput {
        let listed = try await outputs(in: basket)
        guard let index = listed.firstIndex(where: { $0.outpoint.transactionID.displayHex == txid }) else {
            throw LiveSetupError("no output of \(txid) in \(name)'s \(basket) basket (\(listed.count) outputs)")
        }
        let page = try await wallet.listOutputs(try WalletListOutputsRequest(
            basket: basket,
            include: .lockingScripts,
            includeTags: true,
            pagination: try WalletPagination(limit: 1, offset: UInt32(index))
        ))
        guard let output = page.outputs.first, output.outpoint == listed[index].outpoint else {
            throw LiveSetupError("\(basket) basket changed order between reads: expected \(listed[index].outpoint) at \(index), got \(page.outputs.map(\.outpoint))")
        }
        return output
    }

    /// Txids of every action storage lists for this wallet.
    func actionTxids() async throws -> Set<String> {
        var txids: Set<String> = []
        var offset: UInt32 = 0
        while true {
            let page = try await wallet.listActions(try WalletListActionsRequest(
                labels: [],
                pagination: try WalletPagination(limit: 1_000, offset: offset)
            ))
            txids.formUnion(page.actions.map { $0.transactionID.displayHex })
            offset += UInt32(page.actions.count)
            if page.actions.isEmpty || offset >= page.totalActions { return txids }
        }
    }
}
