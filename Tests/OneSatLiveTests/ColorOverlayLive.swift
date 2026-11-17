import BSVNetwork
import BSVOverlay
import Foundation
import OneSatColor
import ToolboxStorage
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The 1Color overlay the app hands the color actions on testnet (`ColorOverlayRouter` with no
/// overrides): every asset at the chain's default origin, `https://testnet.openex.dev`
/// (`ChainEndpoints.colorOverlay`, `Backend.testnetExchange`). Lookups are BRC-24
/// `ls_color_<assetId>` with Yours' query through swift-sdk's HTTPS facilitator; submissions are
/// BRC-22 through `HTTPColorOverlay`, posted through a session the host guard is named on.
///
/// The lookups keep the facilitator's own session (swift-sdk offers no public way to hand it
/// one), bounded by its 15 s request and resource timeouts; they go to the same allowed origin.
struct LiveColorOverlay: ColorOverlayProvider {
    let origin: URL

    static let testnet = LiveColorOverlay(origin: Backend.testnetExchange)

    /// The submit's session: guarded, 30 s a request, 60 s in all.
    static let session = guardedSession(requestTimeout: 30, resourceTimeout: 60)

    /// `HTTPColorOverlay.urlSessionPost`, through `session` instead of `URLSession.shared`.
    static let post: HTTPColorOverlay.Post = { (request: URLRequest) async throws -> (status: Int, body: [UInt8]) in
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, Array(data))
    }

    func spendability(assetID: ColorAssetID, outpoints: [String]) async throws -> ColorOutputList {
        try await query(assetID, type: "color-spendability", outpoints: outpoints)
    }

    func admission(assetID: ColorAssetID, outpoints: [String]) async throws -> ColorOutputList {
        try await query(assetID, type: "color-admission", outpoints: outpoints)
    }

    func submit(topics: [String], beef: [UInt8]) async throws -> [String: ColorAdmittance] {
        try await HTTPColorOverlay(
            baseURL: origin,
            lookup: { _, _, _ in throw ColorError.overlay("lookups go through LiveColorOverlay") },
            post: Self.post
        ).submit(topics: topics, beef: beef)
    }

    private func query(_ assetID: ColorAssetID, type: String, outpoints: [String]) async throws -> ColorOutputList {
        let id = assetID.description
        let list = outpoints.map { "\"\($0)\"" }.joined(separator: ",")
        let text = #"{"type":"\#(type)","version":1,"assetId":"\#(id)","topic":"tm_color_\#(id)","outpoints":[\#(list)]}"#
        let question = try LookupQuestion(service: OverlayService(rawValue: "ls_color_\(id)"), query: Array(text.utf8))
        let facilitator = HTTPSOverlayLookupFacilitator(configuration: try OverlayHTTPConfiguration(
            beefLimits: StorageLimits.beef, requestTimeout: .seconds(15), resourceTimeout: .seconds(15)
        ))
        switch try await facilitator.lookup(question: question, at: try OverlayHost(rawValue: origin.absoluteString)) {
        case .outputList(let items):
            return ColorOutputList(outputs: items.map { .init(beef: $0.beef, outputIndex: $0.outputIndex) })
        case .freeform:
            throw LiveSetupError("1Color overlay \(origin.absoluteString) answered \(type) with a freeform answer")
        }
    }
}
