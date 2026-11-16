// Generator of amm-quote-vectors.json: run by amm-quote-vectors.gen.sh, which lays out the TS it imports.
// Runs skein-amm cc146be (amm-engine / amm-client 0.55.1) TS under bun and writes the inputs and
// canonical outputs the Swift port is checked against (QuoteTests.swift).
import { plan, replan, nextLeg, planOrder, filterLivePools, resolveMinAmountOut } from "@dcasegr/amm-engine";
import { pickBestSingleLeg, minAmountInOf } from "./node_modules/@dcasegr/amm-engine/src/planner.ts";
import { legMinerFeeSats, buildPlanRequest, quote as planQuote, livePools, goneFromLookup } from "./ui/src/market/plan.ts";
import { withLastSeen, validatorStatus } from "./ui/src/market/view.ts";
import { parsePools, liveOfPools } from "./ui/src/lib/overlay.ts";
import { parseAmount } from "./ui/src/lp/amounts.ts";
import { parseSwapTerms, readBytes, callApp } from "./ui/src/market/relay.ts";
import { makeQuoter, legCarrySats, poolFees, poolsWithMinimums, ClientError } from "./clientpure.ts";

// ---- canonical encoding: bigint "n:", number "d:", string "s:", keys sorted, undefined dropped
function enc(v: any): any {
  if (typeof v === "bigint") return "n:" + v.toString();
  if (typeof v === "number") return "d:" + String(v);
  if (typeof v === "string") return "s:" + v;
  if (typeof v === "boolean" || v === null) return v;
  if (v === undefined) return null;
  if (Array.isArray(v)) return v.map(enc);
  const out: any = {};
  for (const k of Object.keys(v).sort()) if (v[k] !== undefined) out[k] = enc(v[k]);
  return out;
}
const canon = (v: any) => JSON.stringify(enc(v));
const errOf = (e: any) => ({ throws: `${e?.name ?? "Error"}: ${e?.message ?? String(e)}`, ...(e instanceof ClientError ? { kind: e.kind } : {}) });

const ps = (p: any) => ({
  outpoint: p.outpoint, bsvReserve: p.bsvReserve, tokenReserve: p.tokenReserve, liquidityFeeBps: p.liquidityFeeBps,
  validationFeeBps: p.validationFeeBps, commissionBps: p.commissionBps, validatorIdentityKey: p.validatorIdentityKey,
  lastSeen: p.lastSeen, minLegSats: p.minLegSats,
});
const planOut = (x: any) => ({ ...x, remainingInventory: x.remainingInventory.map(ps) });

const cases: any[] = [];
function add(kind: string, name: string, input: any, f: () => any) {
  let expect: any;
  try { expect = f(); } catch (e) { expect = errOf(e); }
  cases.push({ kind, name, input: enc(input), expect: canon(expect) });
}

// ---- pools
const VK = (s: string) => "02" + s.repeat(64).slice(0, 64);
const P = (outpoint: string, o: any = {}) => {
  const p: any = {
    outpoint, bsvReserve: o.bsv ?? 10_000_000n, tokenReserve: o.tokens ?? 10_000_000n,
    liquidityFeeBps: o.lp ?? 30n, validationFeeBps: o.val ?? 5n, commissionBps: o.comm ?? 0n,
    validatorIdentityKey: o.vk ?? VK("a"),
  };
  if (o.lastSeen !== undefined) p.lastSeen = o.lastSeen;
  if (o.min !== undefined) p.minLegSats = o.min;
  return p;
};
const three = [P("a:0", { bsv: 1_000_000n, tokens: 5_000_000n }), P("b:0", { bsv: 1_200_000n, tokens: 6_000_000n }), P("c:0", { bsv: 900_000n, tokens: 4_500_000n })];
const commish = [P("a:0", { bsv: 2_000_000n, tokens: 9_000_000n, comm: 10n }), P("b:0", { bsv: 3_100_000n, tokens: 14_000_000n, lp: 25n, val: 0n, comm: 20n }), P("c:0", { bsv: 500_000n, tokens: 2_300_000n, lp: 100n, val: 15n })];
const wide = [P("x:0", { bsv: 2_100_000_000_000_000n, tokens: 21_000_000_000_000n, lp: 25n, val: 5n, comm: 10n }),
  P("y:0", { bsv: 3_000_000_000n, tokens: 40_000_000n }), P("z:0", { bsv: 777_777n, tokens: 123_456_789n, lp: 100n, val: 20n, comm: 5n })];
const twins = [P("b:0"), P("a:0"), P("B:0")];
const zero = [P("z:0", { bsv: 0n, tokens: 0n })];
const drained = [P("d:0", { bsv: 0n, tokens: 5_000_000n }), P("e:0", { bsv: 1_000_000n, tokens: 0n })];
const withMin = three.map((p, i) => (i === 1 ? { ...p, minLegSats: 150_000n } : p));
const allMin = three.map((p) => ({ ...p, minLegSats: 400_000n }));
const nc = { minerFeeSats: 0n };
const fc = { minerFeeSats: 1300n };

// ---- plan
const req = (o: any) => ({ tokenId: "t", direction: "bsvToToken", amountIn: 100_000n, slippage: {}, maxSources: 5, fixedCost: fc, inventory: three, ...o });
const planCases: [string, any][] = [
  ["one pool buy tol 50", req({ inventory: [three[0]], slippage: { toleranceBps: 50n } })],
  ["three split tol 100", req({ amountIn: 600_000n, slippage: { toleranceBps: 100n }, fixedCost: nc })],
  ["three split explicit+tol", req({ amountIn: 600_000n, slippage: { toleranceBps: 100n, minAmountOut: 2_000_000n } })],
  ["three split explicit above", req({ amountIn: 600_000n, slippage: { minAmountOut: 99_000_000n } })],
  ["max1 best", req({ amountIn: 600_000n, maxSources: 1, slippage: { toleranceBps: 30n } })],
  ["max1 explicit excludes all", req({ amountIn: 600_000n, maxSources: 1, slippage: { minAmountOut: 9_000_000n } })],
  ["max1 explicit picks", req({ amountIn: 50_000n, maxSources: 1, slippage: { minAmountOut: 240_000n } })],
  ["max2 sell cost", req({ direction: "tokenToBsv", amountIn: 2_000_000n, maxSources: 2, fixedCost: { minerFeeSats: 5000n } })],
  ["sell all three", req({ direction: "tokenToBsv", amountIn: 3_000_000n, slippage: { toleranceBps: 75n } })],
  ["zero liquidity", req({ inventory: zero })],
  ["zero + good", req({ inventory: [...zero, three[0]] })],
  ["drained buy", req({ inventory: drained })],
  ["drained sell", req({ inventory: drained, direction: "tokenToBsv" })],
  ["tiny 1", req({ amountIn: 1n })],
  ["tiny 3 sell", req({ amountIn: 3n, direction: "tokenToBsv" })],
  ["tiny 7", req({ amountIn: 7n, maxSources: 1 })],
  ["above pool 10x", req({ amountIn: 30_000_000n, slippage: { toleranceBps: 100n } })],
  ["above pool 1000x sell", req({ amountIn: 15_500_000_000n, direction: "tokenToBsv" })],
  ["above pool max1", req({ amountIn: 30_000_000n, maxSources: 1 })],
  ["min folds", req({ inventory: withMin, amountIn: 200_000n, maxSources: 2, fixedCost: nc })],
  ["min unfillable", req({ inventory: allMin, amountIn: 200_000n })],
  ["min unfillable max1", req({ inventory: allMin, amountIn: 200_000n, maxSources: 1 })],
  ["min unfillable sell", req({ inventory: allMin, direction: "tokenToBsv", amountIn: 50_000n })],
  ["min ok", req({ inventory: allMin, amountIn: 500_000n })],
  ["liveness", req({ inventory: [P("a:0", { lastSeen: 1000 }), P("b:0", { lastSeen: 9000 }), P("c:0")], livenessThreshold: 5000, now: 10000 })],
  ["liveness none", req({ inventory: [P("a:0", { lastSeen: 1000 })], livenessThreshold: 5000, now: 10000 })],
  ["liveness no now", req({ inventory: [P("a:0", { lastSeen: 1000 }), P("c:0")], livenessThreshold: 5000 })],
  ["empty", req({ inventory: [] })],
  ["amount 0", req({ amountIn: 0n })],
  ["amount -5", req({ amountIn: -5n })],
  ["fee rounding 9999", req({ inventory: [P("f:0", { lp: 1n, val: 1n, comm: 1n })], amountIn: 9_999n, maxSources: 1 })],
  ["fee rounding 10000", req({ inventory: [P("f:0", { lp: 1n, val: 1n, comm: 1n })], amountIn: 10_000n, maxSources: 1 })],
  ["fee rounding 10001", req({ inventory: [P("f:0", { lp: 1n, val: 1n, comm: 1n })], amountIn: 10_001n, maxSources: 1 })],
  ["fee rounding split", req({ inventory: [P("f:0", { lp: 3n, val: 7n, comm: 1n }), P("g:0", { lp: 3n, val: 7n, comm: 1n, bsv: 9_999_999n })], amountIn: 20_001n, fixedCost: nc })],
  ["commission split", req({ inventory: commish, amountIn: 1_234_567n, slippage: { toleranceBps: 25n } })],
  ["commission sell", req({ inventory: commish, direction: "tokenToBsv", amountIn: 4_444_444n, slippage: { toleranceBps: 25n } })],
  ["wide buy", req({ inventory: wide, amountIn: 987_654_321_987n, fixedCost: { minerFeeSats: 200n } })],
  ["wide sell huge", req({ inventory: wide, direction: "tokenToBsv", amountIn: (1n << 70n) + 12345n, fixedCost: nc })],
  ["tol 10000", req({ slippage: { toleranceBps: 10000n } })],
  ["tol 20000", req({ slippage: { toleranceBps: 20000n } })],
  ["tol -50", req({ slippage: { toleranceBps: -50n } })],
  ["maxSources 0", req({ amountIn: 600_000n, maxSources: 0 })],
  ["maxSources -3", req({ amountIn: 600_000n, maxSources: -3 })],
  ["twins max1", req({ inventory: twins, maxSources: 1 })],
  ["twins split", req({ inventory: twins, amountIn: 3_000_001n, fixedCost: nc })],
  ["neg cancel throws", req({ inventory: [P("n:0", { bsv: -100n, tokens: 5n, lp: 0n, val: 0n })], amountIn: 100n, maxSources: 1 })],
];
for (const [n, r] of planCases) add("plan", n, r, () => planOut(plan(r)));

// ---- pieces
add("resolveMin", "resolve", [[1_000_000n, {}], [1_000_000n, { toleranceBps: 50n }], [1_000_000n, { minAmountOut: 999_000n, toleranceBps: 50n }], [999n, { toleranceBps: 3n }], [-7n, { toleranceBps: 1n }], [1_000_000n, { minAmountOut: -5n }]],
  () => [[1_000_000n, {}], [1_000_000n, { toleranceBps: 50n }], [1_000_000n, { minAmountOut: 999_000n, toleranceBps: 50n }], [999n, { toleranceBps: 3n }], [-7n, { toleranceBps: 1n }], [1_000_000n, { minAmountOut: -5n }]].map(([t, s]: any) => resolveMinAmountOut(t, s)));
for (const [n, pools, d, a, m] of [
  ["best twins", twins, "bsvToToken", 1000n, 0n], ["best three sell", three, "tokenToBsv", 70_000n, 0n],
  ["best min filter", three, "bsvToToken", 100_000n, 413_000n], ["best none", zero, "bsvToToken", 100n, 0n],
  ["best min leg", withMin, "bsvToToken", 100_000n, 0n],
] as any[]) add("best", n, { pools, direction: d, amountIn: a, minAmountOut: m }, () => pickBestSingleLeg(pools, d, a, m));
for (const [n, pools, d] of [["minIn three", allMin, "bsvToToken"], ["minIn sell", allMin, "tokenToBsv"], ["minIn none", zero, "bsvToToken"], ["minIn plain", three, "bsvToToken"], ["minIn empty", [], "tokenToBsv"]] as any[])
  add("minIn", n, { pools, direction: d }, () => minAmountInOf(pools, d));
for (const [n, pools, a, ms, m] of [["order max1", three, 50_000n, 1, 0n], ["order split", three, 50_000n, 3, 0n], ["order empty", [], 5n, 3, 0n]] as any[])
  add("order", n, { pools, direction: "bsvToToken", amountIn: a, maxSources: ms, fixedCost: fc, minAmountOut: m }, () => planOrder(pools, "bsvToToken", a, ms, fc, m));
add("live", "filterLivePools", { pools: [P("a:0", { lastSeen: 0 }), P("b:0", { lastSeen: 5000.5 }), P("c:0"), P("d:0", { lastSeen: 10_001 })], threshold: 5000, now: 10_000 },
  () => filterLivePools([P("a:0", { lastSeen: 0 }), P("b:0", { lastSeen: 5000.5 }), P("c:0"), P("d:0", { lastSeen: 10_001 })], 5000, 10_000).map((p) => p.outpoint));

// ---- replan: rounds of results over plan(request)
const R = (outpoint: string, status: string, newPoolState?: any) => (newPoolState ? { outpoint, status, newPoolState } : { outpoint, status });
const replanCases: [string, any, any[][]][] = [
  ["all filled", req({ amountIn: 600_000n, slippage: { toleranceBps: 100n } }), [[R("a:0", "filled"), R("b:0", "filled"), R("c:0", "filled")]]],
  ["mixed", req({ amountIn: 600_000n, slippage: { toleranceBps: 100n }, inventory: [...three, P("d:0", { bsv: 800_000n, tokens: 4_100_000n })], maxSources: 3 }),
    [[R("a:0", "filled"), R("b:0", "rejected", P("b:1", { bsv: 1_250_000n, tokens: 5_800_000n })), R("c:0", "unknown")]]],
  ["rejected no state, missing", req({ amountIn: 600_000n, slippage: { toleranceBps: 100n } }), [[R("a:0", "rejected")]]],
  ["two rounds", req({ amountIn: 900_000n, slippage: { toleranceBps: 200n }, inventory: [...three, P("d:0", { bsv: 800_000n, tokens: 4_100_000n }), P("e:0", { bsv: 300_000n, tokens: 1_400_000n })], maxSources: 2 }),
    [[R("a:0", "filled"), R("b:0", "rejected", P("b:1", { bsv: 1_210_000n, tokens: 5_950_000n }))], [R("b:1", "filled"), R("d:0", "unknown")]]],
  ["max1 replan", req({ amountIn: 300_000n, maxSources: 1, slippage: { toleranceBps: 50n } }), [[R("a:0", "rejected", P("a:1", { bsv: 1_100_000n, tokens: 4_600_000n }))]]],
  ["duplicates last wins", req({ amountIn: 600_000n }), [[R("a:0", "filled"), R("a:0", "unknown"), R("b:0", "unknown"), R("b:0", "filled"), R("zz:0", "filled")]]],
  ["slippage cumulative miss", req({ amountIn: 600_000n, slippage: { toleranceBps: 10n } }), [[R("a:0", "filled"), R("b:0", "rejected", P("b:1", { bsv: 2_400_000n, tokens: 3_000_000n })), R("c:0", "unknown")]]],
  ["nothing left", req({ amountIn: 600_000n, inventory: [three[0]] }), [[R("a:0", "unknown")]]],
];
for (const [n, r, rounds] of replanCases) {
  add("replan", n, { request: r, rounds }, () => {
    let p = plan(r);
    const out = [planOut(p)];
    for (const results of rounds) { p = replan(p, results as any); out.push(planOut(p)); }
    return out;
  });
}

// ---- nextLeg
const nl = (o: any) => ({ pools: three, direction: "bsvToToken", remaining: 600_000n, fixedCost: fc, minOut: 0n, maxSources: 3, ...o });
for (const [n, r] of [
  ["filled", nl({ remaining: 0n })], ["filled neg", nl({ remaining: -1n })],
  ["max1 ok", nl({ maxSources: 1 })], ["max1 floor", nl({ maxSources: 1, minOut: 9_000_000n })],
  ["max1 min", nl({ maxSources: 1, pools: allMin, remaining: 100_000n })], ["max1 no_pool", nl({ maxSources: 1, pools: zero })],
  ["split ok", nl({})], ["split floor", nl({ minOut: 2_400_000n })], ["split just", nl({ minOut: 2_000_000n })],
  ["split min", nl({ pools: allMin, remaining: 100_000n })], ["split no_pool", nl({ pools: [] })], ["split zero", nl({ pools: zero })],
  ["tie smaller outpoint", nl({ pools: [P("b:0"), P("a:0")], remaining: 2_000_000n, fixedCost: nc })],
  ["sell split", nl({ direction: "tokenToBsv", remaining: 3_000_000n, pools: commish })],
  ["tiny", nl({ remaining: 2n })], ["above pool", nl({ remaining: 50_000_000n })],
] as [string, any][]) add("nextLeg", n, r, () => nextLeg(r));

// ---- legMinerFeeSats, legCarrySats, poolFees
for (const rate of [100, 0, 1, 0.5, 1.07, 7.6923, 250.333, 1e-9, 1e15, -0.5, NaN, Infinity]) add("minerFee", `rate ${rate}`, rate, () => legMinerFeeSats(rate));
for (const [n, leg, buy, fee] of [
  ["buy", { liquidityFee: 3n, validationFee: 1n, commission: 0n }, true, 1300n], ["sell all", { liquidityFee: 3n, validationFee: 1n, commission: 2n }, false, 1300n],
  ["sell none", { liquidityFee: 0n, validationFee: 0n, commission: 0n }, false, 1300n], ["sell lp only", { liquidityFee: 9n, validationFee: 0n, commission: 0n }, false, 0n],
  ["sell neg", { liquidityFee: -1n, validationFee: 5n, commission: 0n }, false, 7n],
] as any[]) add("carry", n, { leg, buy, fee }, () => legCarrySats(leg, buy, fee));
for (const p of [three[0], commish[1], P("q:0", { lp: 10_000n, val: 123_456n, comm: 0n })]) add("fees", p.outpoint, p, () => poolFees(p));

// ---- parseAmount, buildPlanRequest
for (const [t, d] of [["1_000", 0], ["  42 ", 0], ["1.5", 0], ["1.5", 1], [".5", 2], ["5.", 2], [".", 2], ["", 2], ["abc", 0], ["-5", 0], ["1.2.3", 3], ["0.000000000000000001", 18], ["7", 19], ["7", -1], ["١٢", 0], [" 1 ", 0]] as any[])
  add("parseAmount", `${JSON.stringify(t)} ${d}`, { text: t, dec: d }, () => parseAmount(t, d));
const liveAll = (pools: any[]) => ({ now: 5, validators: [...new Set(pools.map((p: any) => p.validatorIdentityKey.toLowerCase()))].map((k) => ({ identityKey: k, peerId: "peer-" + k.slice(2, 6), at: 1234, ageMs: 7, live: true })), kept: true });
const mixedPools = [P("a:0", { vk: VK("A") }), P("b:0", { vk: VK("b") }), P("c:0", { vk: VK("c") })];
const mixedLive = { now: 9, validators: [{ identityKey: VK("a"), peerId: "pa", at: 111, ageMs: 2, live: true }, { identityKey: VK("b"), peerId: "pb", at: 222, ageMs: 3, live: false }], kept: true };
const form = (o: any) => ({ direction: "bsvToToken", amount: "100000", slippageBps: "50", maxSources: 3, ...o });
for (const [n, f, pools, live, dec, rate] of [
  ["ok buy", form({}), three, liveAll(three), 2, 100], ["ok sell dec 2", form({ direction: "tokenToBsv", amount: "1234.56" }), three, liveAll(three), 2, 37.5],
  ["sell dec undefined", form({ direction: "tokenToBsv", amount: "1234" }), three, liveAll(three), undefined, 100],
  ["empty amount", form({ amount: "   " }), three, liveAll(three), 2, 100], ["bad amount", form({ amount: "1e5" }), three, liveAll(three), 2, 100],
  ["too many places", form({ direction: "tokenToBsv", amount: "1.234" }), three, liveAll(three), 2, 100],
  ["zero", form({ amount: "0.0" }), three, liveAll(three), 2, 100],
  ["slip empty", form({ slippageBps: "" }), three, liveAll(three), 2, 100], ["slip spaces", form({ slippageBps: " 75 " }), three, liveAll(three), 2, 100],
  ["slip hex", form({ slippageBps: "0x10" }), three, liveAll(three), 2, 100], ["slip frac", form({ slippageBps: "1.5" }), three, liveAll(three), 2, 100],
  ["slip neg", form({ slippageBps: "-1" }), three, liveAll(three), 2, 100], ["slip big", form({ slippageBps: "10001" }), three, liveAll(three), 2, 100],
  ["slip 10000", form({ slippageBps: "10000" }), three, liveAll(three), 2, 100],
  ["no pools", form({}), [], liveAll(three), 2, 100], ["no live read", form({}), three, null, 2, 100],
  ["not kept", form({}), three, { now: 1, validators: [], kept: false }, 2, 100], ["none live", form({}), three, { now: 1, validators: [], kept: true }, 2, 100],
  ["mixed live", form({}), mixedPools, mixedLive, 2, 100], ["rate NaN", form({}), three, liveAll(three), 2, NaN],
] as any[]) add("build", n, { tokenId: "tok", form: f, pools, live, dec, rate }, () => buildPlanRequest("tok", f, pools, live, dec, rate));
add("status", "validatorStatus", { live: mixedLive }, () => [validatorStatus(VK("A"), mixedLive), validatorStatus(VK("b"), mixedLive), validatorStatus(VK("c"), mixedLive), validatorStatus(VK("a"), null)]);
add("withLastSeen", "withLastSeen", { pools: mixedPools, live: mixedLive }, () => [withLastSeen(mixedPools, mixedLive).map(ps), withLastSeen(mixedPools, null).map(ps), livePools(mixedPools, mixedLive).map((p) => p.outpoint)]);
add("gone", "goneFromLookup", null, () => goneFromLookup({ legs: [{ outpoint: "a:0" }, { outpoint: "b:0" }, { outpoint: "c:0" }] as any }, [three[1]]));

// ---- quoteSwap over a pools route answer (wire JSON)
const T = "ab".repeat(32) + "_0";
const tx = (c: string, v = 0) => c.repeat(64).slice(0, 64) + "_" + v;
const wire = (outpoint: string, o: any = {}) => ({
  outpoint, poolId: (o.poolId ?? outpoint).toUpperCase(), lpPubKey: "03" + "CD".repeat(32), swaps: o.swaps ?? 3,
  bsvReserve: o.bsv ?? 1_000_000, tokenReserve: o.tokens ?? 5_000_000, liquidityFeeBps: o.lp ?? 30, validationFeeBps: o.val ?? 5,
  ...(o.comm !== undefined ? { commissionBps: o.comm } : {}), validatorIdentityKey: o.vk ?? VK("a"),
  ...(o.peer === null ? {} : { validatorPeerId: o.peer ?? "12D3KooWpeer" }),
});
const route = (pools: any[], validators: any[] = [{ identity: VK("a"), peerId: "12D3KooWpeer" }]) => JSON.stringify({ market: { identityKey: VK("e"), minCommissionBps: 0 }, pools, validators });
const W3 = [wire(tx("1"), { bsv: 1_000_000, tokens: 5_000_000 }), wire(tx("2"), { bsv: 1_200_000, tokens: 6_000_000, vk: VK("b"), peer: "12D3KooWb" }), wire(tx("3"), { bsv: "900000", tokens: "4500000", comm: 10 })];
const V3 = [{ identity: VK("a"), peerId: "12D3KooWpeer" }, { identity: VK("b"), peerId: "12D3KooWb", minLegSats: 50_000 }];
const Q = (o: any) => ({ tokenId: T, side: "buy", amountIn: 100_000n, maxSlippageBps: 50, maxSources: 3, ...o });
const quoteCases: [string, string | null, any, any, number][] = [
  ["buy one pool", route([wire(tx("1"))]), Q({}), { sym: "TST", dec: 2 }, 100],
  ["buy three", route(W3, V3), Q({ amountIn: 600_000n }), { sym: "TST", dec: 2 }, 100],
  ["sell three dec 8", route(W3, V3), Q({ side: "sell", amountIn: 250_000_000n, maxSlippageBps: 100 }), { sym: "TST", dec: 8 }, 100],
  ["sell dec 0", route(W3, V3), Q({ side: "sell", amountIn: 2_500_000n }), { sym: "Z", dec: 0 }, 100],
  ["sell dec 18", route(W3, V3), Q({ side: "sell", amountIn: 2_500_000n }), { sym: "Z", dec: 18 }, 100],
  ["sell dec 19", route(W3, V3), Q({ side: "sell", amountIn: 2_500_000n }), { sym: "Z", dec: 19 }, 100],
  ["buy dec 20", route(W3, V3), Q({ amountIn: 77_777n }), { sym: "Z", dec: 20 }, 100],
  ["buy dec -1", route(W3, V3), Q({ amountIn: 77_777n }), { sym: "Z", dec: -1 }, 100],
  ["below minimum buy", route(W3.slice(1, 2), V3), Q({ amountIn: 20_000n }), { sym: "TST", dec: 2 }, 100],
  ["below minimum sell", route([wire(tx("2"), { vk: VK("b"), peer: "pb" })], [{ identity: VK("b"), peerId: "pb", minLegSats: 60_000 }]), Q({ side: "sell", amountIn: 1000n }), { sym: "TST", dec: 2 }, 100],
  ["min split folds", route(W3, V3), Q({ amountIn: 120_000n }), { sym: "TST", dec: 2 }, 100],
  ["too small", route(W3, V3), Q({ amountIn: 1n }), { sym: "TST", dec: 2 }, 100],
  ["tiny 5", route(W3, V3), Q({ amountIn: 5n, maxSources: 1 }), { sym: "TST", dec: 2 }, 100],
  ["above pool", route(W3, V3), Q({ amountIn: 50_000_000n }), { sym: "TST", dec: 2 }, 100],
  ["above pool sell", route(W3, V3), Q({ side: "sell", amountIn: 900_000_000n }), { sym: "TST", dec: 2 }, 100],
  ["amount 0", route(W3, V3), Q({ amountIn: 0n }), { sym: "TST", dec: 2 }, 100],
  ["held null", null, Q({}), { sym: "TST", dec: 2 }, 100],
  ["no pools", route([]), Q({}), { sym: "TST", dec: 2 }, 100],
  ["none live", route([wire(tx("1"), { peer: null })]), Q({}), { sym: "TST", dec: 2 }, 100],
  ["one not live", route([wire(tx("1"), { peer: null }), wire(tx("4"), { vk: VK("c"), peer: "pc", bsv: 2_000_000, tokens: 9_000_000 })]), Q({ amountIn: 300_000n }), { sym: "TST", dec: 2 }, 100],
  ["slip 0", route(W3, V3), Q({ maxSlippageBps: 0 }), { sym: "TST", dec: 2 }, 100],
  ["slip 10000", route(W3, V3), Q({ maxSlippageBps: 10000 }), { sym: "TST", dec: 2 }, 100],
  ["slip 10001", route(W3, V3), Q({ maxSlippageBps: 10001 }), { sym: "TST", dec: 2 }, 100],
  ["slip -1", route(W3, V3), Q({ maxSlippageBps: -1 }), { sym: "TST", dec: 2 }, 100],
  ["max1 of three", route(W3, V3), Q({ amountIn: 600_000n, maxSources: 1 }), { sym: "TST", dec: 2 }, 100],
  ["max5 of three sell", route(W3, V3), Q({ side: "sell", amountIn: 3_000_000n, maxSources: 5 }), { sym: "TST", dec: 2 }, 100],
  ["max7 one pool", route([wire(tx("1"))]), Q({ maxSources: 7 }), { sym: "TST", dec: 2 }, 100],
  ["rate 50", route(W3, V3), Q({ amountIn: 600_000n }), { sym: "TST", dec: 2 }, 50],
  ["rate 0.5", route(W3, V3), Q({ amountIn: 600_000n }), { sym: "TST", dec: 2 }, 0.5],
  ["rate 1.07 sell", route(W3, V3), Q({ side: "sell", amountIn: 600_000n }), { sym: "TST", dec: 2 }, 1.07],
  ["rate 250.333", route(W3, V3), Q({ amountIn: 600_000n }), { sym: "TST", dec: 2 }, 250.333],
  ["sell no fees carriers", route([wire(tx("5"), { lp: 0, val: 0, comm: 0 })]), Q({ side: "sell", amountIn: 400_000n, maxSources: 2 }), { sym: "TST", dec: 2 }, 100],
  ["sell all fees carriers", route([wire(tx("5"), { lp: 30, val: 5, comm: 12 })]), Q({ side: "sell", amountIn: 400_000n, maxSources: 2 }), { sym: "TST", dec: 2 }, 100],
  ["zero liquidity only", route([wire(tx("6"), { bsv: 0, tokens: 0 })]), Q({}), { sym: "TST", dec: 2 }, 100],
  ["zero liquidity + good", route([wire(tx("6"), { bsv: 0, tokens: 0 }), wire(tx("1"))]), Q({}), { sym: "TST", dec: 2 }, 100],
  ["drained bsv buy", route([wire(tx("7"), { bsv: 0, tokens: 5_000_000 }), wire(tx("1"))]), Q({}), { sym: "TST", dec: 2 }, 100],
  ["drained tokens sell", route([wire(tx("8"), { bsv: 900_000, tokens: 0 }), wire(tx("1"))]), Q({ side: "sell", amountIn: 50_000n }), { sym: "TST", dec: 2 }, 100],
  ["uppercase validator", route([wire(tx("1"), { vk: VK("A") })], [{ identity: VK("A"), peerId: "x", minLegSats: 70_000 }]), Q({ amountIn: 69_999n }), { sym: "TST", dec: 2 }, 100],
  ["dup outpoints", route([wire(tx("1"), { poolId: "first" }), wire(tx("1"), { poolId: "second", bsv: 1_100_000 })]), Q({}), { sym: "TST", dec: 2 }, 100],
  ["wide", route([wire(tx("9"), { bsv: "2100000000000000", tokens: "21000000000000", comm: 10, lp: 25 }), wire(tx("1"))]), Q({ amountIn: 987_654_321_987n }), { sym: "BIG", dec: 8 }, 100],
  ["commission three sell", route([wire(tx("1"), { comm: 10 }), wire(tx("2"), { comm: 20, lp: 25, val: 0, bsv: 3_100_000, tokens: 14_000_000 }), wire(tx("3"), { lp: 100, val: 15, bsv: 500_000, tokens: 2_300_000 })]), Q({ side: "sell", amountIn: 4_444_444n, maxSlippageBps: 25 }), { sym: "TST", dec: 3 }, 100],
];
const projView = (v: any) => ({ ...v, legs: v.legs.map((l: any) => ({ ...l, pool: ps(l.pool) })) });
for (const [n, text, r, meta, rate] of quoteCases) {
  add("quote", n, { held: text, request: r, meta, rate }, () => {
    const held = text === null ? null : parsePools(JSON.parse(text));
    const { quoteSwap, planned } = makeQuoter(rate);
    const q: any = quoteSwap(r, held, meta);
    const kept = planned.get(q);
    // The view: the same request planned again (pure), as the client's planQuote made it.
    const pools = poolsWithMinimums(held!);
    const live = liveOfPools(pools);
    const again = planQuote(rebuild(r, pools, live, meta.dec, rate), live, meta.dec);
    if (canon(planOut(again.plan)) !== canon(planOut(kept.plan))) throw new Error("driver: replanned plan differs");
    return { quote: q, plan: planOut(kept.plan), view: projView(again.view) };
  });
}
function rebuild(r: any, pools: any[], live: any, dec: number, rate: number) {
  const buy = r.side === "buy";
  const fmt = (a: bigint, d: number) => { const s = a.toString().padStart(d + 1, "0"); const w = s.slice(0, s.length - d); const f = s.slice(s.length - d).replace(/0+$/, ""); return d === 0 ? s : w + (f ? "." + f : ""); };
  const x: any = buildPlanRequest(r.tokenId, { direction: buy ? "bsvToToken" : "tokenToBsv", amount: fmt(r.amountIn, buy ? 0 : dec), slippageBps: String(r.maxSlippageBps), maxSources: r.maxSources }, pools, live, dec, rate);
  if (!x.ok) throw new Error("driver: " + x.error);
  return x.request;
}

// ---- swap terms: parseSwapTerms, readBytes, callApp
const pkh = Array.from({ length: 20 }, (_, i) => (i * 13 + 7) & 0xff);
const b64 = Buffer.from(pkh).toString("base64").replace(/=+$/, "");
const termsInputs: [string, string][] = [
  ["dag bytes", JSON.stringify({ commissionPkh: { "/": { bytes: b64 } }, minCommissionBps: 25 })],
  ["hex upper", JSON.stringify({ commissionPkh: Buffer.from(pkh).toString("hex").toUpperCase() })],
  ["byte array", JSON.stringify({ commissionPkh: pkh, minCommissionBps: 0 })],
  ["null pkh", JSON.stringify({ commissionPkh: null })], ["empty", "{}"], ["array", "[]"],
  ["min null", JSON.stringify({ minCommissionBps: null })], ["min 10000", JSON.stringify({ minCommissionBps: 10000 })],
  ["min -1", JSON.stringify({ minCommissionBps: -1 })], ["min 1.5", JSON.stringify({ minCommissionBps: 1.5 })],
  ["min 10001", JSON.stringify({ minCommissionBps: 10001 })], ["min string", JSON.stringify({ minCommissionBps: "1" })],
  ["min 2.0", '{"minCommissionBps": 2.0}'], ["min bad before pkh bad", JSON.stringify({ minCommissionBps: -2, commissionPkh: [1] })],
  ["3 bytes", JSON.stringify({ commissionPkh: { "/": { bytes: "AQID" } } })], ["21 bytes", JSON.stringify({ commissionPkh: [...pkh, 1] })],
  ["bad array", JSON.stringify({ commissionPkh: [...pkh.slice(0, 19), 256] })], ["odd hex", JSON.stringify({ commissionPkh: "abc" })],
  ["non-hex string", JSON.stringify({ commissionPkh: "zz".repeat(20) })], ["number pkh", JSON.stringify({ commissionPkh: 5 })],
  ["false pkh", JSON.stringify({ commissionPkh: false })],
  ["b64 url-safe", JSON.stringify({ commissionPkh: { "/": { bytes: Buffer.from(Array(20).fill(0xfb)).toString("base64url") } } })],
  ["b64 spaces", JSON.stringify({ commissionPkh: { "/": { bytes: " " + b64.slice(0, 10) + "\n" + b64.slice(10) + " " } } })],
  ["b64 padded", JSON.stringify({ commissionPkh: { "/": { bytes: Buffer.from(pkh).toString("base64") } } })],
  ["b64 bad char", JSON.stringify({ commissionPkh: { "/": { bytes: b64.slice(0, 10) + "*" + b64.slice(11) } } })],
  ["b64 len%4==1", JSON.stringify({ commissionPkh: { "/": { bytes: b64 + "A" } } })],
  ["bytes not string", JSON.stringify({ commissionPkh: { "/": { bytes: 5 } } })],
  ["null", "null"], ["number", "5"], ["string", JSON.stringify("terms\n\"q\"")], ["true", "true"],
];
for (const [n, text] of termsInputs) add("terms", n, text, () => parseSwapTerms(JSON.parse(text)));
const calls: [string, number, string][] = [
  ["ok", 200, JSON.stringify({ fn: "amm.swap.terms", result: { commissionPkh: pkh, minCommissionBps: 5 } })],
  ["ok result null", 200, JSON.stringify({ fn: "amm.swap.terms", result: null })],
  ["error answer", 400, JSON.stringify({ fn: "amm.swap.terms", error: { code: "unknown-fn", message: "no such fn" } })],
  ["error 200 no result", 200, JSON.stringify({ fn: "amm.swap.terms", error: { code: "bad", message: "nope" } })],
  ["error code not string", 500, JSON.stringify({ error: { code: 5, message: "five" } })],
  ["error message not string", 503, JSON.stringify({ error: { code: "busy" } })],
  ["not json", 502, "<html>bad gateway " + "x".repeat(300) + "</html>"],
  ["empty body", 404, ""], ["json null", 200, "null"], ["json array", 200, "[1,2]"], ["json zero", 200, "0"],
];
for (const [n, status, body] of calls) {
  cases.push({ kind: "call", name: n, input: enc({ status, body }), expect: "" });
}
const callPromises = calls.map(async ([n, status, body], i) => {
  const af = { fetch: async () => ({ status, text: async () => body }) };
  let expect: any;
  try { expect = parseSwapTerms(await callApp(af as any, "https://x/@t/amm", "amm.swap.terms", {})); } catch (e) { expect = errOf(e); }
  cases.find((c) => c.kind === "call" && c.name === n)!.expect = canon(expect);
});
await Promise.all(callPromises);

void readBytes; void validatorStatus;
console.log('{"source":"skein-amm cc146be (@dcasegr/amm-engine and amm-client 0.55.1), @bsv/sdk 4.0.1, run under bun 1.4.4 (JavaScriptCore); generator driver.ts",\n"cases":[\n' + cases.map((c) => JSON.stringify(c)).join(",\n") + "\n]}");
