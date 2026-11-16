import Foundation
import OneSatSweep

/// Turns a 1Sat service's answer into a value or a `OneSatClientError` that says what failed,
/// logging the full detail once where it is thrown.
enum OneSatClientHTTP {
    static let category = "OneSatClient"

    /// Throws `httpFailure` with the service's detail for a non-2xx status.
    static func check(
        _ response: (status: Int, body: [UInt8]),
        service: String, operation: String, method: String, url: URL
    ) throws {
        guard !(200..<300).contains(response.status) else { return }
        let detail = OneSatHTTPFailure(
            service: service, operation: operation, method: method, url: url,
            statusCode: response.status, body: response.body
        )
        detail.log(category: category)
        throw OneSatClientError.httpFailure(statusCode: response.status, detail: detail)
    }

    /// Checks the status, then decodes the JSON body; a body that does not decode is logged with
    /// the decoding error and thrown as `unreadableResponse`.
    static func decode<T: Decodable>(
        _ type: T.Type, _ response: (status: Int, body: [UInt8]),
        service: String, operation: String, method: String, url: URL
    ) throws -> T {
        try check(response, service: service, operation: operation, method: method, url: url)
        do {
            return try JSONDecoder().decode(type, from: Data(response.body))
        } catch {
            OneSatLog.unreadable(operation, method: method, url: url, body: response.body, error: error, category: category)
            throw OneSatClientError.unreadableResponse
        }
    }

    /// Logs a response that arrived but cannot be used, before `unreadableResponse` is thrown.
    static func unreadable(_ operation: String, method: String, url: URL, body: [UInt8], why: String) {
        OneSatLog.error(
            "\(operation): \(method) \(url.host ?? "")\(url.path) answered something unusable (\(why)); body: \(OneSatHTTPFailure.logText(body))",
            category: category
        )
    }
}
