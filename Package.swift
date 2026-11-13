// swift-tools-version: 6.1

import PackageDescription

/// The 1Sat layer: ordinals, tokens, and the ecosystem-specific actions that sit above a generic
/// BRC-100 wallet. This is the Swift counterpart of `b-open-io/1sat-sdk` and the `@1sat/*` packages,
/// the third layer above `swift-sdk` (primitives) and `swift-wallet-toolbox` (the generic wallet).
///
/// Sweep still moves coins from a legacy or foreign key into the wallet's own scheme — the first
/// thing a real wallet needs from this layer. The tree already ships major `@1sat/actions` families
/// — ordinals, BSV21, OpNS, MNEE — alongside templates, addresses, and clients.
let publicModules = [
    "OneSatClient",
    "OneSatPermissions",
    "OneSatSweep",
    "OneSatTemplates",
    "OneSatAddresses",
    "OneSatActions",
    "OneSatCBOR",
    "OneSatColor",
    "OneSatMetanet",
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
            revision: "941557a257cd3a009d61f953b3d913249c1da69b"
        ),
        .package(
            url: "https://github.com/opldotdev/swift-wallet-toolbox.git",
            revision: "0ce3547d2a4d4ddcf28a72459a8a18e30fe3e468"
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

        // Strict DAG-CBOR encode/decode, matching `@ipld/dag-cbor` as the TS stack uses it.
        // Pure Swift, no dependencies. Used by 1Color payloads (and later the OpNS record).
        .target(name: "OneSatCBOR", dependencies: []),

        // 1Sat locking scripts: inscription envelope, OrdLock v2, BSV-20, BSV-21, 1Color (BRC-162),
        // Cosign, BAP, BitCom, public MAPTemplate, and CLTV time-lock. Byte-exact with
        // `@1sat/templates`. Unlock templates live with the action families.
        .target(
            name: "OneSatTemplates",
            dependencies: [
                "OneSatCBOR",
                .product(name: "BSVCore", package: "swift-sdk"),
                .product(name: "BSVCrypto", package: "swift-sdk"),
                .product(name: "BSVKeys", package: "swift-sdk"),
                .product(name: "BSVScript", package: "swift-sdk"),
            ]
        ),

        // P1SAT deposit addresses: protocol [0, "onesat"], keyID "1sat <index>".
        // Matches `@1sat/actions` `deriveDepositAddresses`.
        .target(
            name: "OneSatAddresses",
            dependencies: [
                .product(name: "BSVKeys", package: "swift-sdk"),
            ]
        ),

        // Read-only views of the ordinals and BSV-21 balances held by an address. The client uses
        // the same categorised owner stream as sweep while retaining inscription and token data.
        .target(
            name: "OneSatClient",
            dependencies: [
                "OneSatSweep",
                .product(name: "BSVKeys", package: "swift-sdk"),
                .product(name: "BSVScript", package: "swift-sdk"),
                .product(name: "ToolboxCore", package: "swift-wallet-toolbox"),
                .product(name: "ToolboxServices", package: "swift-wallet-toolbox"),
            ]
        ),

        // Serializable, native approval-review models plus best-effort live verification for
        // 1Sat assets. Canonical BRC-116 grant authority remains in swift-wallet-toolbox.
        .target(
            name: "OneSatPermissions",
            dependencies: [
                "OneSatClient",
                "OneSatTemplates",
                .product(name: "BSVCore", package: "swift-sdk"),
                .product(name: "BSVCrypto", package: "swift-sdk"),
                .product(name: "BSVKeys", package: "swift-sdk"),
                .product(name: "BSVScript", package: "swift-sdk"),
                .product(name: "BSVWallet", package: "swift-sdk"),
                .product(name: "ToolboxPermissions", package: "swift-wallet-toolbox"),
            ]
        ),

        // BRC-207 color custody for 1Color (BRC-162): identifiers, action plans, receipts, overlay
        // admission and spendability. Wire-compatible with `@bopen-io/color-permission-module`
        // 0.2.2, so a Swift wallet and a TS wallet can share one storage account.
        // Metanet delivery: BRC-169 handles and signed envelopes, BRC-78 framing, BRC-232
        // transaction delivery, and the BRC-231 DAG-CBOR message relay. Ported from
        // `@1sat/actions` `metanet/` and `@1sat/client` handles.
        .target(
            name: "OneSatMetanet",
            dependencies: [
                "OneSatCBOR",
                .product(name: "BSVCore", package: "swift-sdk"),
                .product(name: "BSVCrypto", package: "swift-sdk"),
                .product(name: "BSVKeys", package: "swift-sdk"),
                .product(name: "BSVWallet", package: "swift-sdk"),
                .product(name: "ToolboxWallet", package: "swift-wallet-toolbox"),
            ]
        ),

        // The 1Color actions (deploy, send, balances, inbox receive) live here too, above
        // `OneSatActions` and `OneSatMetanet`, so neither of those depends on the other.
        .target(
            name: "OneSatColor",
            dependencies: [
                "OneSatTemplates",
                "OneSatCBOR",
                "OneSatActions",
                "OneSatMetanet",
                .product(name: "BSVInterpreter", package: "swift-sdk"),
                .product(name: "ToolboxActions", package: "swift-wallet-toolbox"),
                .product(name: "ToolboxBRC29", package: "swift-wallet-toolbox"),
                .product(name: "ToolboxStorage", package: "swift-wallet-toolbox"),
                .product(name: "ToolboxStorageClient", package: "swift-wallet-toolbox"),
                .product(name: "BSVCore", package: "swift-sdk"),
                .product(name: "BSVCrypto", package: "swift-sdk"),
                .product(name: "BSVKeys", package: "swift-sdk"),
                .product(name: "BSVScript", package: "swift-sdk"),
                .product(name: "BSVTransaction", package: "swift-sdk"),
                .product(name: "BSVOverlay", package: "swift-sdk"),
                .product(name: "BSVWallet", package: "swift-sdk"),
            ]
        ),

        // Action families from `@1sat/actions`: tracked create/sign, ordinals, inscribe,
        // BSV-21 transfer, locks, and marketplace. Spend-side unlock templates live here.
        .target(
            name: "OneSatActions",
            dependencies: [
                "OneSatClient",
                "OneSatTemplates",
                "OneSatAddresses",
                "OneSatCBOR",
                .product(name: "BSVCompat", package: "swift-sdk"),
                .product(name: "BSVCore", package: "swift-sdk"),
                .product(name: "BSVCrypto", package: "swift-sdk"),
                .product(name: "BSVKeys", package: "swift-sdk"),
                .product(name: "BSVScript", package: "swift-sdk"),
                .product(name: "BSVTransaction", package: "swift-sdk"),
                .product(name: "BSVWallet", package: "swift-sdk"),
                .product(name: "ToolboxActions", package: "swift-wallet-toolbox"),
                .product(name: "ToolboxBRC29", package: "swift-wallet-toolbox"),
                .product(name: "ToolboxStorage", package: "swift-wallet-toolbox"),
                .product(name: "ToolboxStorageClient", package: "swift-wallet-toolbox"),
                .product(name: "ToolboxServices", package: "swift-wallet-toolbox"),
                .product(name: "ToolboxCore", package: "swift-wallet-toolbox"),
            ]
        ),

        .testTarget(
            name: "OneSatSweepTests",
            dependencies: [
                "OneSatSweep",
                "OneSatTemplates",
                .product(name: "BSVKeys", package: "swift-sdk"),
                .product(name: "BSVTransaction", package: "swift-sdk"),
                .product(name: "ToolboxServices", package: "swift-wallet-toolbox"),
            ]
        ),
        .testTarget(
            name: "OneSatMetanetTests",
            dependencies: [
                "OneSatMetanet",
                "OneSatCBOR",
                .product(name: "BSVCore", package: "swift-sdk"),
                .product(name: "BSVCrypto", package: "swift-sdk"),
                .product(name: "BSVKeys", package: "swift-sdk"),
                .product(name: "BSVWallet", package: "swift-sdk"),
            ],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "OneSatColorTests",
            dependencies: [
                "OneSatColor",
                "OneSatTemplates",
                "OneSatActions",
                "OneSatMetanet",
                "OneSatCBOR",
                .product(name: "BSVInterpreter", package: "swift-sdk"),
                .product(name: "BSVWallet", package: "swift-sdk"),
                .product(name: "ToolboxActions", package: "swift-wallet-toolbox"),
                .product(name: "ToolboxAuth", package: "swift-wallet-toolbox"),
                .product(name: "ToolboxBRC29", package: "swift-wallet-toolbox"),
                .product(name: "ToolboxStorage", package: "swift-wallet-toolbox"),
                .product(name: "ToolboxStorageClient", package: "swift-wallet-toolbox"),
                .product(name: "ToolboxCore", package: "swift-wallet-toolbox"),
                .product(name: "BSVCore", package: "swift-sdk"),
                .product(name: "BSVKeys", package: "swift-sdk"),
                .product(name: "BSVScript", package: "swift-sdk"),
                .product(name: "BSVTransaction", package: "swift-sdk"),
            ]
        ),
        .testTarget(
            name: "OneSatCBORTests",
            dependencies: ["OneSatCBOR"]
        ),
        .testTarget(
            name: "OneSatTemplatesTests",
            dependencies: [
                "OneSatTemplates",
                "OneSatCBOR",
                .product(name: "BSVCore", package: "swift-sdk"),
                .product(name: "BSVCrypto", package: "swift-sdk"),
                .product(name: "BSVKeys", package: "swift-sdk"),
                .product(name: "BSVScript", package: "swift-sdk"),
                .product(name: "BSVTransaction", package: "swift-sdk"),
            ],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "OneSatAddressesTests",
            dependencies: [
                "OneSatAddresses",
                .product(name: "BSVKeys", package: "swift-sdk"),
                .product(name: "ToolboxWallet", package: "swift-wallet-toolbox"),
            ]
        ),
        .testTarget(
            name: "OneSatClientTests",
            dependencies: [
                "OneSatClient",
                .product(name: "ToolboxServices", package: "swift-wallet-toolbox"),
            ]
        ),
        .testTarget(
            name: "OneSatPermissionsTests",
            dependencies: [
                "OneSatPermissions",
                "OneSatClient",
                "OneSatTemplates",
                .product(name: "BSVScript", package: "swift-sdk"),
                .product(name: "BSVTransaction", package: "swift-sdk"),
                .product(name: "BSVWallet", package: "swift-sdk"),
                .product(name: "ToolboxPermissions", package: "swift-wallet-toolbox"),
                .product(name: "ToolboxStorage", package: "swift-wallet-toolbox"),
            ]
        ),
        .testTarget(
            name: "OneSatActionsTests",
            dependencies: [
                "OneSatActions",
                "OneSatTemplates",
                .product(name: "BSVCompat", package: "swift-sdk"),
                .product(name: "BSVInterpreter", package: "swift-sdk"),
                .product(name: "BSVCore", package: "swift-sdk"),
                .product(name: "BSVKeys", package: "swift-sdk"),
                .product(name: "BSVScript", package: "swift-sdk"),
                .product(name: "BSVTransaction", package: "swift-sdk"),
                .product(name: "BSVWallet", package: "swift-sdk"),
                .product(name: "ToolboxActions", package: "swift-wallet-toolbox"),
                .product(name: "ToolboxAuth", package: "swift-wallet-toolbox"),
                .product(name: "ToolboxBRC29", package: "swift-wallet-toolbox"),
                .product(name: "ToolboxCore", package: "swift-wallet-toolbox"),
                .product(name: "ToolboxStorage", package: "swift-wallet-toolbox"),
                .product(name: "ToolboxStorageClient", package: "swift-wallet-toolbox"),
                .product(name: "ToolboxServices", package: "swift-wallet-toolbox"),
                "OneSatAddresses",
                "OneSatCBOR",
                "OneSatClient",
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
