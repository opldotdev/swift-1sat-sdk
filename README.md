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

The tree now has more than sweep and read-only balances. **Sweep** still moves coins from a
foreign or legacy key into a wallet's own address — generic over source, destination, and UTXO
provider; the client still reads categorised owner outputs from the 1Sat indexer. Alongside that:
P1SAT deposit addresses, 1Sat locking templates, MNEE and OpNS clients, and the `@1sat/actions`
families (ordinals, inscriptions, token transfers, locks, collections, identity, OpNS, MNEE,
and asset sweep onto P1SAT outputs).

Sweep stays **partial by design**. Further `@1sat` surface lands as the wallet needs it.

## Modules

| Module | Responsibility |
|---|---|
| `OneSatClient` | Read-only ordinals and BSV-21 balances; MNEE and OpNS clients; 1sat-stack services |
| `OneSatSweep` | Categorise an address, sweep its fundable BSV, report the rest |
| `OneSatTemplates` | Locking scripts: inscription, OrdLock, BSV-20/21, Cosign, TimeLock, BAP, BitCom |
| `OneSatAddresses` | P1SAT deposit addresses (`[0, "p 1sat"]`, keyID `"1sat <index>"`) |
| `OneSatActions` | Action families from `@1sat/actions`, including spend-side unlock templates |
| `OneSat` | Umbrella, re-exporting the above |

## Sweep

A sweep is **partial by nature**. A legacy address rarely holds only plain BSV — it may hold
ordinals, BSV-21 tokens, and time-locked outputs. Sweeping all of them would burn a collectible as
a fee or build an invalid transaction. So the safe flow categorises first, sweeps the fundable BSV,
and **reports what remains** — keeping the source key while any asset is still there, exactly as
Yours Wallet's migration does.

```swift
import OneSatSweep

// 1. Categorise through the 1Sat indexer (the only provider that can tell an ordinal from a coin).
let plan = try await Sweep.plan(forAddress: legacyAddress, scanner: OneSatScanner())

// 2. Sweep only the fundable BSV.
if !plan.fundable.isEmpty {
    let result = try Sweep.build(fromWIF: legacyWIF, toAddress: myWalletAddress, utxos: plan.fundable)
    // broadcast result.transaction
}

// 3. Keep the key while anything remains; re-sweep after the next lock unlocks.
if !plan.remaining.isEmpty {
    // preserve legacyWIF; plan.remaining.nextUnlockHeight tells you when to try again
}
```

### Two provider families

| Family | Gives | Use for |
|---|---|---|
| **WhatsOnChain** | plain UTXOs, no asset tags | balance, plain-BSV-only sweep (`WhatsOnChainUTXOSource`) |
| **1Sat / GorillaPool** (`api.1sat.app`, junglebus, Banana Blocks) | UTXOs **with** event tags (`bsv21:`, `lock:`, ordinal) | any sweep that could hold assets (`AssetScanner`) |

A sweep that might touch assets **must** read from the 1Sat family — WhatsOnChain cannot tell a
high-value ordinal from a coin. The wallet's provider setting selects which family answers. Both adapters are built and
live-verified: `WhatsOnChainUTXOSource` and `OneSatScanner` (`api.1sat.app`).

## Building

```bash
swift build
swift test
```

## License

[MIT](LICENSE)
