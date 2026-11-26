#!/bin/sh
# Rebuilds ordlock-list-vectors.json from the TypeScript it is checked against, under bun (no npm):
#   sh ordlock-list-vectors.gen.sh <b-open-io/1sat-sdk checkout at 71fd3ba> <empty work dir>
# The checkout is exported to the work dir, installed with `bun install`, and the workspace packages
# @1sat/actions imports are built with tsc; the driver then runs the real `buildListOrdinal`,
# `sellOrdinal` and `sellOpns` over a ProtoWallet for the ActionVectors identity.
set -eu
SDK=$1
W=$2
HERE=$(cd "$(dirname "$0")" && pwd)
test "$(git -C "$SDK" rev-parse HEAD)" = 71fd3ba7cabce11be7be2a66db77e80bf14a8194
git -C "$SDK" archive HEAD | tar -x -C "$W"
(cd "$W" && bun install)
for p in types templates utils client wallet wallet-remote; do
  (cd "$W/packages/$p" && bun run build)
done
cp "$HERE/ordlock-list-vectors.gen.ts" "$W/packages/actions/driver.ts"
(cd "$W/packages/actions" && bun run driver.ts) > "$HERE/ordlock-list-vectors.json"
