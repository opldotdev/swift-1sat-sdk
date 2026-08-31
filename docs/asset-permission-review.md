# Asset-aware permission reviews

Swift keeps the same boundary as the current TypeScript stack:

- `swift-wallet-toolbox` remains the canonical, protocol-neutral BRC-116 authority.
- The ordinary storage baskets remain `1sat`, `bsv21`, `opns`, and `lock`.
- `OneSatPermissions` carries approval-time display data and live asset checks. It is not a
  basket, grant store, or second permissions manager.
- Native UI renders `OneSatAssetPermissionReview`; it does not reclassify scripts or trust tags.

For BSV21, a review starts `unverified`. `Bsv21PermissionVerifier` checks the current token detail
and, when available, every spent token outpoint against the overlay with `unspent=true`. Both the
response `tokenId` and nested `token.id` must identify the token that was requested.
An inactive token, conflicting symbol, or missing input is `mismatch`. Missing services, HTTP
errors, malformed responses, and timeouts stay `unverified` and never crash or suppress the
approval prompt. A `verified` result describes that lookup only and must not be persisted as an
asset property.

This matches `@1sat/permission-module` / `@1sat/permission-module-ui` and Yours Wallet v5.0.3.
The still-separate host task is BRC-99 module dispatch for protected `createAction`,
`createSignature`, `listOutputs`, and `internalizeAction`; Swift must not claim those routes are
supported until the generic toolbox exposes an explicit registered-module hook.
