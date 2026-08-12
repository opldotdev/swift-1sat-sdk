<div align="center">

# 1Sat SDK for Swift

**Ordinals, tokens, and 1Sat-ecosystem actions above a generic BRC-100 wallet.**

<a href="https://www.swift.org/"><img src="https://img.shields.io/badge/Swift-6.1%2B-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift 6.1 or later"></a>
<a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="MIT License"></a>

</div>

## What this is

The third Swift layer for BSV, above two that already exist:

| Layer | Repo | What it holds |
|---|---|---|
| Primitives | [`swift-sdk`](https://github.com/opldotdev/swift-sdk) | keys, crypto, transactions, BEEF, the BRC-100 ABI |
| Generic wallet | [`swift-wallet-toolbox`](https://github.com/opldotdev/swift-wallet-toolbox) | remote storage, the action lifecycle, `RemoteWallet` |
| **1Sat ecosystem** | **this** | ordinals, BSV21 tokens, OpNS, MNEE, sweep — the protocol-specific actions |

It is the Swift counterpart of [`b-open-io/1sat-sdk`](https://github.com/b-open-io/1sat-sdk) and the
`@1sat/*` packages. It depends on both layers below it.

## Status

Early. The first module is **sweep** — moving coins from a foreign or legacy key into a wallet's
own address — because that is the first thing a real wallet needs from this layer: taking in money
held under another scheme. It is generic over source, destination, and UTXO provider.

Next, in the order the wallet app needs them: 1Sat ordinals templates and indexers (real Pass
data), then ordinals/BSV21 transfers, then OpNS and MNEE.

## Modules

| Module | Responsibility |
|---|---|
| `OneSatSweep` | Sweep P2PKH coins from a key to a destination address |
| `OneSat` | Umbrella, re-exporting the above |

## Sweep

```swift
import OneSatSweep

let result = try await Sweep.build(
    fromWIF: legacyWIF,
    toAddress: myWalletAddress,
    source: WhatsOnChainUTXOSource()   // or any configured provider
)
// result.transaction is signed; broadcast it however the wallet is configured.
```

Sweep is deliberately **not** asset-aware: it moves standard P2PKH outputs. An ordinal or token has
a non-standard script and is handled by the asset layer, which knows never to spend a collectible
as a fee. Point sweep at a plain-BSV key, or at the BSV outputs an asset scan already separated.

## Building

```bash
swift build
swift test
```

## License

[MIT](LICENSE)
