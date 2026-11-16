import BSVNetwork
import BSVOverlay
import Foundation
import OneSatColor
import ToolboxStorage

/// The 1Color overlay the app hands the color actions on testnet (`ColorOverlayRouter` with no
/// overrides): every asset at the chain's default origin, `https://testnet.openex.dev`
/// (`ChainEndpoints.colorOverlay`). Lookups are BRC-24 `ls_color_<assetId>` with Yours' query
/// through swift-sdk's HTTPS facilitator; submissions are BRC-22 through `HTTPColorOverlay`.
struct LiveColorOverlay: ColorOverlayProvider {
    let origin: URL

    static let testnet = LiveColorOverlay(origin: URL(string: "https://testnet.openex.dev")!)

    func spendability(assetID: ColorAssetID, outpoints: [String]) async throws -> ColorOutputList {
        try await query(assetID, type: "color-spendability", outpoints: outpoints)
    }

    func admission(assetID: ColorAssetID, outpoints: [String]) async throws -> ColorOutputList {
        try await query(assetID, type: "color-admission", outpoints: outpoints)
    }

    func submit(topics: [String], beef: [UInt8]) async throws -> [String: ColorAdmittance] {
        try await HTTPColorOverlay(
            baseURL: origin,
            lookup: { _, _, _ in throw ColorError.overlay("lookups go through LiveColorOverlay") }
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
