#!/bin/sh
# Rebuilds amm-swap-vectors.json from the TypeScript it is checked against, under bun (no npm):
#   sh amm-swap-vectors.gen.sh <skein-amm checkout at cc146be (v0.55.1)> <empty work dir>
# web/ui/src, the engine (web/engine/src), web/ui/test/brc29Wallet.ts and the topic vectors are
# copied verbatim; the published packages are pinned below and installed with `bun install`.
# The driver seeds crypto.getRandomValues, so a rebuild gives the same bytes.
set -eu
SKEIN=$1
W=$2
HERE=$(cd "$(dirname "$0")" && pwd)
test "$(git -C "$SKEIN" rev-parse HEAD)" = cc146bea6fe6d6bf4b2a14cb775870ab28e8726f
mkdir -p "$W/test/fixtures"
cp -R "$SKEIN/web/ui/src" "$W/src"
cp "$SKEIN/web/ui/test/brc29Wallet.ts" "$W/test/brc29Wallet.ts"
cp "$SKEIN/web/ui/test/fixtures/amm-topic-vectors.json" "$W/test/fixtures/amm-topic-vectors.json"
cat > "$W/package.json" <<'JSON'
{"name":"i4gen","private":true,"type":"module","dependencies":{"@bsv/sdk":"4.0.1","@1sat/actions":"0.1.6","@1sat/templates":"0.1.1","@bsv/color-permission-module":"npm:@bopen-io/color-permission-module@0.2.3"}}
JSON
(cd "$W" && bun install)
mkdir -p "$W/node_modules/@dcasegr/amm-engine"
cp -R "$SKEIN/web/engine/src" "$W/node_modules/@dcasegr/amm-engine/src"
echo '{"name":"@dcasegr/amm-engine","version":"0.55.1","type":"module","main":"src/index.ts","exports":{".":"./src/index.ts"}}' \
  > "$W/node_modules/@dcasegr/amm-engine/package.json"
cp "$HERE/amm-swap-vectors.gen.ts" "$W/driver.ts"
(cd "$W" && bun run driver.ts) > "$HERE/amm-swap-vectors.json"
