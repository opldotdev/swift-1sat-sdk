import BSVKeys
import Foundation

/// 1Sat API hosts per chain. Mirrors `@1sat/types` `ONESAT_MAINNET_URL`, `ONESAT_TESTNET_URL`,
/// `ONESAT_MAINNET_CONTENT_URL` and `ONESAT_TESTNET_CONTENT_URL`.
public enum OneSatAPI {
    public static let mainnetURL = URL(string: "https://api.1sat.app")!
    public static let testnetURL = URL(string: "https://testnet.api.1sat.app")!
    public static let mainnetContentURL = URL(string: "https://api.1sat.app/content")!
    public static let testnetContentURL = URL(string: "https://testnet.api.1sat.app/content")!

    /// The API base for `network`. Pass it as `baseURL` to every 1Sat client.
    public static func baseURL(for network: BitcoinNetwork) -> URL {
        switch network {
        case .mainnet: mainnetURL
        case .testnet: testnetURL
        }
    }

    /// Where inscription content is served for `network`.
    public static func contentURL(for network: BitcoinNetwork) -> URL {
        switch network {
        case .mainnet: mainnetContentURL
        case .testnet: testnetContentURL
        }
    }
}
