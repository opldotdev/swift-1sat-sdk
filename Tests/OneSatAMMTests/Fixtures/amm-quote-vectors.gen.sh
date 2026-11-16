#!/bin/sh
# Rebuilds amm-quote-vectors.json from the TypeScript it is checked against, under bun (no npm):
#   sh amm-quote-vectors.gen.sh <skein-amm checkout at cc146be (v0.55.1)> <empty work dir>
# The engine (web/engine/src) and the UI files are copied verbatim; the client's pure quote
# functions are cut verbatim out of web/ui/src/client.ts and errors.ts; @bsv/sdk is the 4.0.1
# tarball from the npm registry.
set -eu
SKEIN=$1
W=$2
HERE=$(cd "$(dirname "$0")" && pwd)
test "$(git -C "$SKEIN" rev-parse HEAD)" = cc146bea6fe6d6bf4b2a14cb775870ab28e8726f
mkdir -p "$W/node_modules/@dcasegr/amm-engine" "$W/node_modules/@bsv/sdk"
cp -R "$SKEIN/web/engine/src" "$W/node_modules/@dcasegr/amm-engine/src"
echo '{"name":"@dcasegr/amm-engine","version":"0.55.1","type":"module","main":"src/index.ts","exports":{".":"./src/index.ts"}}' \
  > "$W/node_modules/@dcasegr/amm-engine/package.json"
curl -sSfL https://registry.npmjs.org/@bsv/sdk/-/sdk-4.0.1.tgz | tar -xz -C "$W/node_modules/@bsv/sdk" --strip-components=1
for f in lp/amounts.ts lib/config.ts lib/overlay.ts lib/tokenId.ts market/view.ts market/relay.ts market/plan.ts; do
  mkdir -p "$W/ui/src/$(dirname "$f")"
  cp "$SKEIN/web/ui/src/$f" "$W/ui/src/$f"
done
C=$SKEIN/web/ui/src/client.ts
E=$SKEIN/web/ui/src/errors.ts
{
echo '// Generated: verbatim extracts of skein-amm cc146be web/ui/src/client.ts (poolFees..legCarrySats, quoteSwap) and errors.ts (ClientError).'
echo 'import { priceOf, type Leg, type PoolState, type PricePair } from "@dcasegr/amm-engine";'
echo 'import { outpointText } from "./ui/src/lib/tokenId.ts";'
echo 'import { liveOfPools, type PoolsAnswer, type PoolRow } from "./ui/src/lib/overlay.ts";'
echo 'import { buildPlanRequest, legMinerFeeSats, quote as planQuote } from "./ui/src/market/plan.ts";'
echo 'import { formatAmount } from "./ui/src/lp/amounts.ts";'
sed -n '/^export class ClientError/,/^}/p' "$E"
sed -n '/^export function poolFees/,/^export function legCarrySats/p' "$C"
sed -n '/^export function legCarrySats/,/^}/p' "$C" | tail -n +2
echo 'export function makeQuoter(feeRate: number) {'
echo '  const planned = new WeakMap<any, any>();'
sed -n '/^  function quoteSwap(req: QuoteRequest/,/^  }$/p' "$C"
echo '  return { quoteSwap, planned };'
echo '}'
} > "$W/clientpure.ts"
cp "$HERE/amm-quote-vectors.gen.ts" "$W/driver.ts"
(cd "$W" && bun run driver.ts) > "$HERE/amm-quote-vectors.json"
