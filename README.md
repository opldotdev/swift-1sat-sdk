<div align="center">

# 1Sat SDK for Swift

**Ordinals, tokens and 1Sat-ecosystem actions above a generic BRC-100 wallet.**

<a href="https://www.swift.org/"><img src="https://img.shields.io/badge/Swift-6.1%2B-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift 6.1 or later"></a>
<a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="MIT License"></a>

</div>

The Swift counterpart of [`b-open-io/1sat-sdk`](https://github.com/b-open-io/1sat-sdk) and the
`@1sat/*` packages. Locking scripts match `@1sat/templates` byte for byte, and a Swift wallet and a
TypeScript wallet can share one storage account.

It is the third layer of the Swift BSV stack:

| Layer | Repo | Provides |
|---|---|---|
| Primitives | [`swift-sdk`](https://github.com/opldotdev/swift-sdk) | Keys, crypto, transactions, BEEF, the BRC-100 interface |
| Wallet | [`swift-wallet-toolbox`](https://github.com/opldotdev/swift-wallet-toolbox) | Remote storage, the action lifecycle, permissions |
| **1Sat** | **this repo** | Ordinals, tokens, names, handles and the actions that use them |

## Features

- **Ordinals and inscriptions:** inscribe, transfer, collections, and buy or cancel OrdLock v2 listings.
- **BSV-21 tokens:** deploy, mint, send and purchase, gated on the overlay's output status, with overlay funding.
- **1Color (BRC-162):** deploy, mint, send to a handle and receive, with BRC-207 custody compatible with `@bopen-io/color-permission-module`.
- **Handles and delivery:** BRC-169 handle resolution, signed envelopes, BRC-232 transaction delivery, the messagebox relay, and the paymail payment inbox.
- **OpNS:** register and resolve names through a signed PushDrop identity bind.
- **ORDFS:** read content and metadata, and deploy directories with manifests and VCDIFF patches.
- **Identity, locks and more:** BAP identity and SIGMA signing, time locks, MNEE, P1SAT deposit addresses, and sweeping legacy keys.
- **Mainnet and testnet:** set per context.

OrdLock listing create is off for now. Buying and cancelling existing v2 listings work.

## Modules

| Module | Purpose |
|---|---|
| `OneSatActions` | The `@1sat/actions` families: ordinals, tokens, inscriptions, OpNS, locks, identity, ORDFS deploy |
| `OneSatColor` | 1Color actions and BRC-207 custody |
| `OneSatMetanet` | Handles, envelopes, transaction delivery, relay, paymail inbox |
| `OneSatTemplates` | Locking scripts: inscription, OrdLock v2, BSV-20/21, 1Color, Cosign, TimeLock, BAP, MAP, B |
| `OneSatClient` | Read clients for ordinals, BSV-21, OpNS, ORDFS and MNEE |
| `OneSatPermissions` | Approval-time review data for 1Sat assets |
| `OneSatAddresses` | P1SAT deposit addresses |
| `OneSatCBOR` | Strict DAG-CBOR, matching `@ipld/dag-cbor` |
| `OneSatSweep` | Sweep plain BSV from a legacy key and report the assets left behind |
| `OneSat` | Umbrella that re-exports every module except `OneSatColor` and `OneSatMetanet` |

## Install

```swift
dependencies: [
    .package(url: "https://github.com/opldotdev/swift-1sat-sdk.git", branch: "main")
],
targets: [
    .target(name: "MyWallet", dependencies: [
        .product(name: "OneSat", package: "swift-1sat-sdk"),
        .product(name: "OneSatColor", package: "swift-1sat-sdk"),
    ])
]
```

Requires Swift 6.1 and iOS 16, macOS 13, tvOS 16, watchOS 9 or visionOS 1.

## Usage

Actions run against a `OneSatContext`: the wallet's identity key plus a `swift-wallet-toolbox`
storage client.

```swift
import OneSat

let ctx = OneSatContext(
    identity: identityKey,
    storage: storage,
    auth: auth,
    chain: .test,
    bsv21: bsv21Services
)

// Send BSV-21 tokens to an address.
let result = await Tokens.send(ctx, Tokens.SendRequest(
    tokenId: tokenId,
    recipients: [.init(amount: 1_000, destination: .address(recipientAddress))]
))
```

1Color sends go to a handle and arrive through the recipient's transaction inbox:

```swift
import OneSatColor

let colorCtx = OneColorContext(ctx, overlay: colorOverlay)

// Sender
let sent = await OneColorActions.send(colorCtx, assetID: "<txid>_<vout>", amount: 300, to: "@bob@1sat.app")

// Recipient
let inbox = await TransactionInbox.sync(colorCtx)
let balance = try await OneColorActions.balance(colorCtx, assetID: ColorAssetID("<txid>_<vout>"))
```

Most actions return a result with a `txid` on success or an `error` string rather than throwing.

## Development

```bash
swift build
swift test
```

[`AGENTS.md`](AGENTS.md) lists the TypeScript references each change is checked against.
[`docs/`](docs) holds design notes.

## License

[MIT](LICENSE)
