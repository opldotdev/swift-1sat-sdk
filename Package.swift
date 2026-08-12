// swift-tools-version: 6.1

import PackageDescription

/// The 1Sat layer: ordinals, tokens, and the ecosystem-specific actions that sit above a generic
/// BRC-100 wallet. This is the Swift counterpart of `b-open-io/1sat-sdk` and the `@1sat/*` packages,
/// the third layer above `swift-sdk` (primitives) and `swift-wallet-toolbox` (the generic wallet).
///
/// It starts with sweep, because sweep is the first thing a real wallet needs from this layer:
/// moving coins from a legacy or foreign key into the wallet's own scheme. The module grows toward
/// the full `@1sat/actions` surface — ordinals, BSV21, OpNS, MNEE — one boundary at a time.
let publicModules = [
    "OneSatSweep"
]

let package = Package(
    name: "swift-1sat-sdk",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "OneSat", targets: ["OneSat"])
    ] + publicModules.map { .library(name: $0, targets: [$0]) },
    dependencies: [
        // Both pinned to a revision, so CI builds the same bytes twice. `swift-sdk` supplies the
        // primitives; `swift-wallet-toolbox` supplies the chain services (the UTXO source) and the
        // generic wallet a 1Sat action executes against.
        .package(
            url: "https://github.com/opldotdev/swift-sdk.git",
            revision: "ebdac0d87e77986894344f143f63b1ba5fdf5184"
        ),
        .package(
            url: "https://github.com/opldotdev/swift-wallet-toolbox.git",
            revision: "9c8afa7f6357ba170c400ded650bccf51041cd2c"
        ),
    ],
    targets: [
        .target(
            name: "OneSat",
            dependencies: publicModules.map { .target(name: $0) }
        ),

        // Sweeping coins from one key into a destination address. Generic over source and
        // destination; the UTXO source and broadcaster are injected, so it works against any
        // provider the wallet has configured.
        .target(
            name: "OneSatSweep",
            dependencies: [
                .product(name: "BSVKeys", package: "swift-sdk"),
                .product(name: "BSVScript", package: "swift-sdk"),
                .product(name: "BSVTransaction", package: "swift-sdk"),
                .product(name: "ToolboxCore", package: "swift-wallet-toolbox"),
                .product(name: "ToolboxServices", package: "swift-wallet-toolbox"),
            ]
        ),

        .testTarget(
            name: "OneSatSweepTests",
            dependencies: [
                "OneSatSweep",
                .product(name: "BSVKeys", package: "swift-sdk"),
                .product(name: "BSVTransaction", package: "swift-sdk"),
                .product(name: "ToolboxServices", package: "swift-wallet-toolbox"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
