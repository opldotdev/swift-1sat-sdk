// Generator of amm-swap-vectors.json: run by amm-swap-vectors.gen.sh, which lays out the TS it imports.
// Runs skein-amm cc146be (0.55.1) web/ui/src under bun against the fake BRC-100 wallet of
// web/ui/test/swap.test.ts (a KeyDeriver over key(31); the fixture's funds held by key(30)) and
// writes what the Swift port is checked against (SwapLegTests.swift, SwapRecoveryTests.swift, the sell's
// SwapSellTests.swift). The sell cases come after every buy case, so the buy vectors keep their bytes.
// Randomness is seeded: crypto.getRandomValues draws from a counter, so the staged key ids repeat.
let seed = 0;
(globalThis.crypto as any).getRandomValues = (a: Uint8Array) => {
  for (let i = 0; i < a.length; i++) a[i] = (seed++ * 37 + 11) & 0xff;
  return a;
};

import { BigNumber, ECDSA, Beef, P2PKH, PrivateKey, PublicKey, Transaction, UnlockingScript, LockingScript, Utils } from "@bsv/sdk";
import { computeSwap, type Leg, type PoolState } from "@dcasegr/amm-engine";
import { brc29Side } from "./test/brc29Wallet.ts";
import v from "./test/fixtures/amm-topic-vectors.json";
import { PoolTemplate } from "./src/pool/index.ts";
import { deriveCommissionPkh, deriveFirstValidatorPubKey, deriveValidatorPubKey } from "./src/lib/keys.ts";
import { SWAP_BASKET, SWAP_PROTOCOL, LIST_LIMIT, swapInstructions, swapSatsInstructions } from "./src/wallet/color.ts";
import {
  LEG_CHANGE_PREFIX, LEG_COMMISSION_PREFIX, LEG_PAYOUT_PREFIX, P2PKH_UNLOCK_LENGTH, changeKeyID, legDerivation, legNeed,
  prepareSwap, selectLegInputs, takeInOutputs, satsInputsOf, type PlanLegInput, type PreparedSwap, type SatsInput,
} from "./src/market/swapAction.ts";
import { parseSwapReply, swapBody, toPoolState } from "./src/market/relay.ts";
import { relaySwap, swapIdOf } from "./src/market/swapFlow.ts";
import { SWAP_KEY_MARK, SWAP_KEY_PREFIX, SWAP_STAGE_LABEL, fileStagedToken, moveBack, moveBackSats, stage, swapKeyDescription, swapKeyIdOfDescription, unfiledStagedTokens } from "./src/market/activeSwap.ts";
import { assetIdOf, submissionBeef, tokenInputsOf, type TokenInput } from "./src/market/swapAction.ts";
import { tokenP2pkhScript } from "./src/lp/poolDeploy.ts";
import { steakText, submitToOverlay } from "./src/lp/close.ts";
import { legTakeInOf, ownKeyInputOf, resolveFromOverlay } from "./src/wallet/swapPayouts.ts";

const TXID = "948b532f1de8f7bb148f77da824544fe47b02079e7514d5b6a42856651c5214c";
const TOKEN_ID = `${TXID}_0`;
const key = (n: number) => new PrivateKey(n.toString(16).padStart(2, "0").repeat(32), 16);
const taker = key(30);
const identity = key(0x7f);
const anyone = new PrivateKey(1).toPublicKey();
const walletRoot = key(31);
const RATE = 100;
const fund = Transaction.fromHex(v.fund);
const poolDeploy = Transaction.fromHex(v.pool_deploy);
const atomic = (tx: Transaction) => {
  const b = new Beef();
  b.mergeTransaction(tx);
  return b.toBinaryAtomic(tx.id("hex"));
};
const hex = (b: number[] | Uint8Array) => Utils.toHex(Array.from(b));
const big = (x: any): any => (typeof x === "bigint" ? x.toString() : Array.isArray(x) ? x.map(big) : x && typeof x === "object" ? Object.fromEntries(Object.entries(x).map(([k, y]) => [k, big(y)])) : x);

/** swap.test.ts `fakeWallet`, the calls the buy makes: keys, signatures, listOutputs (the held rows), internalizeAction, createAction (recorded). */
function fakeWallet() {
  const side = brc29Side(walletRoot);
  const held: Transaction[] = [];
  const rows: any[] = [];
  const created: any[] = [];
  const w = {
    async getPublicKey(a: any) { return a.identityKey ? { publicKey: side.identityKey } : { publicKey: side.publicKey(a) }; },
    async createSignature(a: any) { return { signature: ECDSA.sign(new BigNumber(a.hashToDirectlySign), side.privateKey(a), true).toDER() as number[] }; },
    async listOutputs(a: any) {
      const b = new Beef();
      b.mergeTransaction(poolDeploy);
      for (const t of held) b.mergeTransaction(t);
      return { totalOutputs: rows.length, outputs: a.basket === SWAP_BASKET ? rows : [], BEEF: b.toBinary() };
    },
    async internalizeAction(a: any) { return side.internalizeAction(a); },
    async createAction(a: any) {
      created.push(a);
      const tx = new Transaction();
      tx.addInput({ sourceTXID: fund.id("hex"), sourceOutputIndex: 1, sourceTransaction: fund, unlockingScript: new UnlockingScript(), sequence: 0xffffffff });
      for (const x of a.outputs ?? []) tx.addOutput({ satoshis: x.satoshis, lockingScript: LockingScript.fromHex(x.lockingScript) });
      tx.inputs[0]!.unlockingScript = await new P2PKH().unlock(taker).sign(tx, 0);
      return { txid: tx.id("hex"), tx: atomic(tx) };
    },
  };
  return { wallet: w as any, side, held, rows, created };
}

let satsKeyN = 0;
/** swap.test.ts `stagedSats`: an amm-swap sats row funded from fund:1, held by the fake wallet. */
async function stagedSats(w: ReturnType<typeof fakeWallet>, satoshis: number, order?: string): Promise<SatsInput> {
  const keyID = `amm-swap-s${++satsKeyN}`;
  const pub = w.side.publicKey({ protocolID: SWAP_PROTOCOL, keyID, counterparty: "self", forSelf: true } as any);
  const tx = new Transaction();
  tx.addInput({ sourceTXID: fund.id("hex"), sourceOutputIndex: 1, sourceTransaction: fund, unlockingScript: new UnlockingScript(), sequence: 0xffffffff });
  tx.addOutput({ satoshis, lockingScript: new P2PKH().lock(PublicKey.fromString(pub).toAddress()) });
  tx.addOutput({ satoshis: fund.outputs[1]!.satoshis! - satoshis - 200, lockingScript: new P2PKH().lock(taker.toAddress()) });
  tx.inputs[0]!.unlockingScript = await new P2PKH().unlock(taker).sign(tx, 0);
  w.held.push(tx);
  const txid = tx.id("hex");
  const ci = swapSatsInstructions({ protocolID: SWAP_PROTOCOL, keyID, counterparty: "self", ...(order ? { order } : {}) });
  w.rows.push({ outpoint: `${txid}.0`, satoshis, lockingScript: tx.outputs[0]!.lockingScript.toHex(), spendable: true, customInstructions: ci, tags: [] });
  return { outpoint: `${txid}.0`, txid, vout: 0, satoshis, lockingScript: tx.outputs[0]!.lockingScript.toHex(), protocolID: SWAP_PROTOCOL, keyID, counterparty: "self" };
}

const stateOf = (tx: Transaction, validatorIdentityKey: string): PoolState => {
  const pool = PoolTemplate.decode(tx.outputs[0]!.lockingScript)!;
  return { outpoint: `${tx.id("hex")}_0`, bsvReserve: BigInt(tx.outputs[0]!.satoshis!), tokenReserve: pool.state.tokenReserve, liquidityFeeBps: pool.args.lpFeeBps, validationFeeBps: pool.args.validatorFeeBps, commissionBps: pool.args.commissionBps, validatorIdentityKey };
};
const legFor = (pool: PoolState, amountIn: bigint): Leg => {
  const s = computeSwap(pool, "bsvToToken", amountIn)!;
  return { outpoint: pool.outpoint, amountIn, liquidityFee: s.liquidityFee, validationFee: s.validationFee, commission: s.commission, amountOut: s.amountOut, newBsvReserve: s.newBsvReserve, newTokenReserve: s.newTokenReserve };
};
const probe: SatsInput = { outpoint: `${"ff".repeat(32)}.0`, txid: "ff".repeat(32), vout: 0, satoshis: 1_000_000_000, lockingScript: "76a914" + "00".repeat(20) + "88ac", protocolID: SWAP_PROTOCOL, keyID: "probe", counterparty: "self" };
const vkey = identity.deriveChild(anyone, `1-amm pool-${v.nonce}`);

async function validatorSigns(p: PreparedSwap, raw: number[]): Promise<Transaction> {
  const tx = Transaction.fromBinary(raw);
  tx.inputs.forEach((inp, n) => (inp.sourceTransaction = p.swap.inputs[n]!.sourceTransaction));
  await PoolTemplate.signPoolInput({ tx, pool: p.plan.pool, method: "swap", unsigned: ["validator"] }, "validator", vkey);
  return tx;
}

/** satsIn of swap.test.ts: 20,000 sats into pool_deploy:0, rows of the need plus `extra` each. */
async function satsIn(name: string, o: { commissionPkh?: string | null; extra?: number[]; last?: boolean; order?: string; amountIn?: bigint }) {
  const w = fakeWallet();
  const pool = stateOf(poolDeploy, v.identity);
  const leg = legFor(pool, o.amountIn ?? 20_000n);
  const common: PlanLegInput = { wallet: w.wallet, tokenId: TOKEN_ID, meta: { sym: "TST", dec: 0 }, direction: "bsvToToken", leg, pool, poolOutput: { beef: atomic(poolDeploy), outputIndex: 0 }, commissionPkh: o.commissionPkh === undefined ? v.commissionPkh : o.commissionPkh, satsPerKb: RATE };
  const need = selectLegInputs(common, [probe], [])!.need;
  const rows: SatsInput[] = [];
  for (const extra of o.extra ?? [0]) rows.push(await stagedSats(w, need.need + extra));
  const inputs = selectLegInputs(common, rows, [])!;
  const prepared = await prepareSwap({ ...common, inputs, last: o.last ?? false, ...(o.order ? { order: o.order } : {}) });
  const signed = await validatorSigns(prepared, prepared.swap.toBinary());
  return {
    w, prepared, signed,
    out: {
      name, commissionPkh: common.commissionPkh, last: o.last ?? false, order: o.order ?? null, amountIn: String(leg.amountIn),
      leg: big(leg), pool: big(pool), rows: w.held.map((t) => t.toHex()), rowSats: rows.map((r) => r.satoshis), rowKeyIDs: rows.map((r) => r.keyID),
      need: big(need), selected: inputs.sats.map((r) => r.outpoint),
      plan: { outputs: prepared.plan.outputs.map((x) => ({ satoshis: String(x.satoshis), script: x.script })), maxCallUnlockLength: PoolTemplate.maxCallUnlockLength(prepared.plan) },
      swap: prepared.swap.toHex(), id: swapIdOf(prepared), funding: hex(prepared.funding.atomicBeef), fee: prepared.funding.fee,
      order: prepared.order, commission: big({ amount: prepared.commission.amount, pkh: prepared.commission.pkh, to: prepared.commission.to }),
      takeIn: takeInOutputs(prepared), body: JSON.stringify(swapBody({ funding: prepared.funding.atomicBeef, swap: prepared.swap.toBinary(), pool: prepared.pool, validator: prepared.validator, peerId: "peer-1" })),
      signed: signed.toHex(), signedTxid: signed.id("hex"),
    },
  };
}

const out: any = {};
out.names = {
  basket: SWAP_BASKET, protocolID: SWAP_PROTOCOL, keyPrefix: SWAP_KEY_PREFIX, stageLabel: SWAP_STAGE_LABEL, keyMark: SWAP_KEY_MARK, listLimit: LIST_LIMIT,
  p2pkhUnlockLength: P2PKH_UNLOCK_LENGTH, payoutPrefix: LEG_PAYOUT_PREFIX, commissionPrefix: LEG_COMMISSION_PREFIX, changePrefix: LEG_CHANGE_PREFIX,
  derivations: ["payout", "commission", "change"].map((k) => ({ input: `${"ab".repeat(32)}.3`, which: k, ...legDerivation(`${"ab".repeat(32)}.3`, k as any) })),
  changeKeyID: changeKeyID(`${"cd".repeat(32)}.7`),
  swapInstructions: swapInstructions({ protocolID: SWAP_PROTOCOL, keyID: "amm-swap-0a", counterparty: "self" }),
  swapInstructionsOrder: swapInstructions({ protocolID: SWAP_PROTOCOL, keyID: "amm-swap-0a", counterparty: "self", order: `${"ab".repeat(32)}.3` }),
  swapSatsInstructions: swapSatsInstructions({ protocolID: SWAP_PROTOCOL, keyID: "amm-swap-0a", counterparty: "self" }),
  swapSatsInstructionsOrder: swapSatsInstructions({ protocolID: SWAP_PROTOCOL, keyID: "amm-swap-0a", counterparty: "self", order: `${"ab".repeat(32)}.3` }),
};
const deployTxid = poolDeploy.id("hex");
out.keys = {
  identity: v.identity, nonce: v.nonce, txid: deployTxid, vout: 0,
  validatorPubKey: deriveValidatorPubKey(v.identity, { txid: deployTxid, vout: 0 }),
  firstValidatorPubKey: deriveFirstValidatorPubKey(v.identity, v.nonce),
  commissionPkh: deriveCommissionPkh(v.identity, { txid: deployTxid, vout: 0 }),
  commissionPkh5: deriveCommissionPkh(walletRoot.toPublicKey().toString(), { txid: "ab".repeat(32), vout: 5 }),
};

out.legs = [];
const relayCase = await satsIn("relay commission, exact need", {});
out.legs.push(relayCase.out);
out.legs.push((await satsIn("change kept in the basket (not the last leg)", { extra: [5_000] })).out);
out.legs.push((await satsIn("the last leg: change a BRC-29 payment", { extra: [5_000], last: true })).out);
const ownCase = await satsIn("own commission (no relay address), last", { commissionPkh: null, extra: [3_000], last: true });
out.legs.push(ownCase.out);
out.legs.push((await satsIn("a later leg of an order", { extra: [2_000], order: `${"ab".repeat(32)}.3` })).out);
out.legs.push((await satsIn("two rows, largest first", { extra: [-3_000, 9_000] })).out);

// The relay (swapFlow.relaySwap) with a host that answers the validator's transaction: the take-in it makes.
{
  const p = relayCase.prepared;
  const replyBody = { ok: true, tx: { "/": { bytes: Utils.toBase64(relayCase.signed.toBinary()).replace(/=+$/, "") } }, txid: relayCase.signed.id("hex") };
  const calls: any[] = [];
  const w = relayCase.w;
  const wallet = { ...w.wallet, internalizeAction: async (a: any) => { calls.push(a); return w.side.internalizeAction(a); } };
  let posted: any;
  const outcome: any = await relaySwap({ wallet, base: "https://ex.test/@" + TOKEN_ID + "/amm", fetch: async (url: string, init: any) => { posted = { url, init }; return { status: 200, text: async () => JSON.stringify(replyBody) }; } }, p, "peer-1");
  out.relay = {
    url: posted.url, headers: posted.init.headers, body: posted.init.body, reply: JSON.stringify(replyBody), status: outcome.status, txid: outcome.txid,
    internalize: calls.map((c) => ({ description: c.description, labels: c.labels, outputs: c.outputs })),
  };
}
out.replies = [
  { ok: true, tx: "00ff", txid: "aa" },
  { ok: false, reason: "pool_spent", detail: "at x", pool: { outpoint: `${"aa".repeat(32)}_0`, bsvReserve: 10, tokenReserve: "20", lpFeeBps: 30, validatorFeeBps: 5, validatorIdentity: "02" + "11".repeat(32) } },
  { ok: false, reason: "unreachable" },
  { ok: false, reason: "bad", pool: { outpoint: "x", closed: true, bsvReserve: 1, tokenReserve: 1, liquidityFeeBps: 1, validationFeeBps: 1, validatorIdentityKey: "02" } },
].map((r) => ({ reply: JSON.stringify(r), parsed: JSON.stringify(big(parseSwapReply(r))) }));

// stage (sats only) and moveBackSats: the createAction each sends.
{
  const w = fakeWallet();
  seed = 0;
  const staged = await stage(w.wallet, { sats: 12_345 }, { sym: "TST" });
  const long = await stage(w.wallet, { sats: 1 }, { sym: "A very long token symbol for the swap description test" });
  out.stage = { random: hex(Array.from({ length: 16 }, (_, i) => (i * 37 + 11) & 0xff)), args: big(w.created), keyID: staged.sats!.keyID, longKeyID: long.sats!.keyID };
}
{
  const w = fakeWallet();
  const a = await stagedSats(w, 4_000);
  const b = await stagedSats(w, 6_000, `${"ab".repeat(32)}.3`);
  let created: any;
  let signed: any;
  const wallet = {
    ...w.wallet,
    async createAction(args: any) {
      created = args;
      const tx = new Transaction();
      for (const i of args.inputs) {
        const [txid, vout] = i.outpoint.split(".");
        const src = w.held.find((t) => t.id("hex") === txid)!;
        tx.addInput({ sourceTXID: txid, sourceOutputIndex: Number(vout), sourceTransaction: src, unlockingScript: new UnlockingScript(), sequence: 0xffffffff });
      }
      tx.addOutput({ satoshis: 9_000, lockingScript: new P2PKH().lock(taker.toAddress()) });
      return { signableTransaction: { tx: atomic(tx), reference: "ref-1" } };
    },
    async signAction(args: any) { signed = args; return { txid: "00".repeat(32), tx: [] }; },
  };
  try { await moveBackSats(wallet as any); } catch { /* the fake's signAction returns no transaction */ }
  out.moveBack = { rows: w.held.map((t) => t.toHex()), args: { ...big(created), inputBEEF: undefined }, spends: signed?.spends ?? null };
}

// The overlay pass: legTakeInOf / ownKeyInputOf over the validator-signed legs, and resolveFromOverlay's internalize call.
out.takeIn = [];
for (const c of [relayCase, ownCase]) {
  const tx = c.signed;
  const own = ownKeyInputOf(tx);
  out.takeIn.push({ signed: tx.toHex(), ownKeyInput: own, outputs: await legTakeInOf(c.w.wallet, tx, TOKEN_ID, own!), other: await legTakeInOf(c.w.wallet, tx, TOKEN_ID, `${"ee".repeat(32)}.0`) });
}
{
  const c = relayCase;
  const w = c.w;
  const calls: any[] = [];
  const wallet = { ...w.wallet, internalizeAction: async (a: any) => { calls.push(a); return { accepted: true }; } };
  const spendsAsked: string[][] = [];
  const signedBeef = (() => { const b = new Beef(); b.mergeTransaction(c.signed); return b.toBinaryAtomic(c.signed.id("hex")); })();
  let first = true;
  const r = await resolveFromOverlay(wallet as any, {
    spendsAll: async (ops) => { spendsAsked.push(ops); const answer = first ? ops.map((o) => ({ outpoint: o, tokenId: TOKEN_ID, spentBy: c.signed.id("hex") })) : []; first = false; return answer; },
    tx: async () => signedBeef,
  });
  out.resolve = { spendsAsked, taken: big(r.taken), stuck: r.stuck, internalize: calls.map((x) => ({ description: x.description, labels: x.labels, outputs: x.outputs })) };
}

// executeSwap's leg: the commission key derived from the market identity per pool outpoint (0.49.0), the whole
// amount in one leg (last), 5,000 sats over the need.
out.loop = (await satsIn("the swap loop's leg", { commissionPkh: deriveCommissionPkh(v.identity, { txid: deployTxid, vout: 0 }), extra: [5_000], last: true })).out;

// ---------------------------------------------------------------------------
// The sell (tokenToBsv): token rows in the swap basket, the leg, its take-in, staging with tokens, the
// token move back, the unfiled staged tokens, and the page's submit (submissionBeef, submitToOverlay).
// ---------------------------------------------------------------------------

let tokenKeyN = 0;
/** An `amm-swap` token row of `amount` (what `stage` files, or a sell leg's change kept), funded from fund:1, held by the fake wallet. */
async function stagedTokens(w: ReturnType<typeof fakeWallet>, amount: bigint, order?: string): Promise<TokenInput> {
  const keyID = `amm-swap-t${++tokenKeyN}`;
  const pub = w.side.publicKey({ protocolID: SWAP_PROTOCOL, keyID, counterparty: "self", forSelf: true } as any);
  const script = tokenP2pkhScript(TOKEN_ID, amount, pub);
  const tx = new Transaction();
  tx.addInput({ sourceTXID: fund.id("hex"), sourceOutputIndex: 1, sourceTransaction: fund, unlockingScript: new UnlockingScript(), sequence: 0xffffffff });
  tx.addOutput({ satoshis: 1, lockingScript: LockingScript.fromHex(script) });
  tx.addOutput({ satoshis: fund.outputs[1]!.satoshis! - 1 - 300, lockingScript: new P2PKH().lock(taker.toAddress()) });
  tx.inputs[0]!.unlockingScript = await new P2PKH().unlock(taker).sign(tx, 0);
  w.held.push(tx);
  const txid = tx.id("hex");
  const ci = swapInstructions({ protocolID: SWAP_PROTOCOL, keyID, counterparty: "self", ...(order ? { order } : {}) });
  const row = { outpoint: `${txid}.0`, satoshis: 1, lockingScript: script, spendable: true, customInstructions: ci, tags: [] };
  w.rows.push(row);
  return tokenInputsOf([row], TOKEN_ID)[0]!;
}

const sellLegFor = (pool: PoolState, amountIn: bigint): Leg => {
  const s = computeSwap(pool, "tokenToBsv", amountIn)!;
  return { outpoint: pool.outpoint, amountIn, liquidityFee: s.liquidityFee, validationFee: s.validationFee, commission: s.commission, amountOut: s.amountOut, newBsvReserve: s.newBsvReserve, newTokenReserve: s.newTokenReserve };
};

/** Tokens in on pool_deploy:0: the token rows `tokens`, then sats rows of the leg's need plus `extra` each. */
async function tokensOut(name: string, o: { commissionPkh?: string | null; tokens: bigint[]; amountIn: bigint; extra?: number[]; last?: boolean; order?: string }) {
  const w = fakeWallet();
  const pool = stateOf(poolDeploy, v.identity);
  const leg = sellLegFor(pool, o.amountIn);
  const common: PlanLegInput = { wallet: w.wallet, tokenId: TOKEN_ID, meta: { sym: "TST", dec: 0 }, direction: "tokenToBsv", leg, pool, poolOutput: { beef: atomic(poolDeploy), outputIndex: 0 }, commissionPkh: o.commissionPkh === undefined ? v.commissionPkh : o.commissionPkh, satsPerKb: RATE };
  const tokenRows: TokenInput[] = [];
  for (const a of o.tokens) tokenRows.push(await stagedTokens(w, a));
  const need = selectLegInputs(common, [probe], tokenRows)!.need;
  const satsRows: SatsInput[] = [];
  for (const extra of o.extra ?? [0]) satsRows.push(await stagedSats(w, need.need + extra));
  const inputs = selectLegInputs(common, satsRows, tokenRows)!;
  const prepared = await prepareSwap({ ...common, inputs, last: o.last ?? false, ...(o.order ? { order: o.order } : {}) });
  const signed = await validatorSigns(prepared, prepared.swap.toBinary());
  return {
    w, prepared, signed,
    out: {
      name, commissionPkh: common.commissionPkh, last: o.last ?? false, order: o.order ?? null, amountIn: String(leg.amountIn),
      leg: big(leg), pool: big(pool),
      tokenRows: tokenRows.map((r) => ({ hex: w.held.find((t) => t.id("hex") === r.txid)!.toHex(), keyID: r.keyID, amount: String(r.amount) })),
      satsRows: satsRows.map((r) => ({ hex: w.held.find((t) => t.id("hex") === r.txid)!.toHex(), keyID: r.keyID, satoshis: r.satoshis })),
      need: big(need), selected: inputs.sats.map((r) => r.outpoint), selectedTokens: inputs.tokens.map((r) => r.outpoint),
      plan: { outputs: prepared.plan.outputs.map((x) => ({ satoshis: String(x.satoshis), script: x.script })), maxCallUnlockLength: PoolTemplate.maxCallUnlockLength(prepared.plan) },
      swap: prepared.swap.toHex(), id: swapIdOf(prepared), funding: hex(prepared.funding.atomicBeef), fee: prepared.funding.fee,
      order: prepared.order, commission: big({ amount: prepared.commission.amount, pkh: prepared.commission.pkh, to: prepared.commission.to }),
      takeIn: takeInOutputs(prepared), body: JSON.stringify(swapBody({ funding: prepared.funding.atomicBeef, swap: prepared.swap.toBinary(), pool: prepared.pool, validator: prepared.validator, peerId: "peer-1" })),
      signed: signed.toHex(), signedTxid: signed.id("hex"),
    },
  };
}

out.sellLegs = [];
const sellRelay = await tokensOut("sell: relay commission, the token change kept (not the last leg)", { tokens: [60_000n], amountIn: 50_000n });
out.sellLegs.push(sellRelay.out);
out.sellLegs.push((await tokensOut("sell, the last leg: the token change a receipt, the sats change a BRC-29 payment", { tokens: [60_000n], amountIn: 50_000n, extra: [4_000], last: true })).out);
const sellOwn = await tokensOut("sell: own commission (a token receipt), the tokens exact, last", { commissionPkh: null, tokens: [50_000n], amountIn: 50_000n, extra: [3_000], last: true });
out.sellLegs.push(sellOwn.out);
out.sellLegs.push((await tokensOut("sell: token rows largest first, as many as cover amountIn", { tokens: [5_000n, 30_000n, 25_000n], amountIn: 50_000n })).out);
out.sellLegs.push((await tokensOut("sell: a later leg of an order", { tokens: [50_000n], amountIn: 50_000n, extra: [1_000], order: `${"ab".repeat(32)}.3` })).out);

// The overlay pass's take-in of a sell leg (its key input the first token input).
out.sellTakeIn = [];
for (const c of [sellRelay, sellOwn]) {
  const tx = c.signed;
  const own = ownKeyInputOf(tx);
  out.sellTakeIn.push({ signed: tx.toHex(), ownKeyInput: own, outputs: await legTakeInOf(c.w.wallet, tx, TOKEN_ID, own!), other: await legTakeInOf(c.w.wallet, tx, TOKEN_ID, `${"ee".repeat(32)}.0`) });
}

// executeSwap's sell leg: the market's commission key, the whole amount in one leg (last), 5,000 sats over the need.
out.sellLoop = (await tokensOut("the swap loop's sell leg", { commissionPkh: deriveCommissionPkh(v.identity, { txid: deployTxid, vout: 0 }), tokens: [50_000n], amountIn: 50_000n, extra: [5_000], last: true })).out;

// `stage` with tokens: the createAction (the module transfer plan), the page's submit and the filing of the token row.
{
  const steak = (topic: string) => ({ steak: { [topic]: { outputsToAdmit: [0], coinsToRetain: [], coinsRemoved: [] } } });
  const runs: any[] = [];
  const cases: [string, number, boolean][] = [["sats and tokens", 2_000, true], ["tokens alone, the submit and the filing refused", 0, false]];
  for (const [name, sats, ok] of cases) {
    const w = fakeWallet();
    const submits: any[] = [];
    const internalized: any[] = [];
    const wallet = { ...w.wallet, internalizeAction: async (a: any) => { internalized.push(a); if (!ok) throw new Error("the wallet is locked"); return w.side.internalizeAction(a); } };
    seed = 0;
    const r = await stage(wallet as any, { sats, tokens: { tokenId: TOKEN_ID, amount: 50_000n } }, {
      sym: "TST",
      submit: async (topic: string, beef: number[]) => { submits.push({ topic, in: hex(beef), out: hex(submissionBeef(topic, beef)) }); if (!ok) throw new Error("POST https://ex.test/submit: 500 down"); return steak(topic); },
    });
    runs.push({
      name, sats, args: big(w.created), submits, internalize: internalized.map((c) => ({ description: c.description, labels: c.labels, outputs: c.outputs })),
      result: big({ txid: r.txid, sats: r.sats ?? null, tokens: r.tokens ?? null, filed: r.filed, submitted: r.submitted, errors: r.errors }),
    });
  }
  out.stageTokens = { random: hex(Array.from({ length: 32 }, (_, i) => (i * 37 + 11) & 0xff)), runs };
  let threw = "";
  try { await stage(fakeWallet().wallet, { sats: 0 }); } catch (e) { threw = (e as Error).message; }
  out.stageTokens.nothing = threw;
}
out.keyDescriptions = [
  ["TST for a swap", "amm-swap-0a1b"],
  ["A very long token symbol for the swap description test for a swap", `amm-swap-${"ab".repeat(16)}`],
].map(([readable, keyID]) => ({ readable, keyID, description: swapKeyDescription(readable!, keyID!) }));
out.keyIdsOfDescriptions = ["TST for a swap · amm-swap 0a1b", "x · amm-swap abc", "x · amm-swap 0A1B", "no mark", `y · amm-swap ${"cd".repeat(64)}`, `y · amm-swap ${"cd".repeat(65)}`]
  .map((d) => ({ description: d, keyID: swapKeyIdOfDescription(d) }));

// `moveBack` with tokens: the module plan (the owned output 0 to a new receiving key), the rows' spends, the page's submit.
{
  const cases: [string, bigint[], number[]][] = [["token rows and sats rows", [30_000n, 20_000n], [4_000]], ["token rows alone", [7_000n], []]];
  out.moveBackTokens = [];
  for (const [name, tokens, sats] of cases) {
    const w = fakeWallet();
    const tokenRows: TokenInput[] = [];
    for (const [n, a] of tokens.entries()) tokenRows.push(await stagedTokens(w, a, n === 1 ? `${"ab".repeat(32)}.3` : undefined));
    const satsRows: SatsInput[] = [];
    for (const s of sats) satsRows.push(await stagedSats(w, s));
    let created: any;
    let signed: any;
    let built: Transaction | undefined;
    const submits: any[] = [];
    const wallet = {
      ...w.wallet,
      async createAction(args: any) {
        created = args;
        const tx = new Transaction();
        for (const i of args.inputs) {
          const [txid, vout] = i.outpoint.split(".");
          const src = w.held.find((t) => t.id("hex") === txid)!;
          tx.addInput({ sourceTXID: txid, sourceOutputIndex: Number(vout), sourceTransaction: src, unlockingScript: new UnlockingScript(), sequence: 0xffffffff });
        }
        for (const o of args.outputs) tx.addOutput({ satoshis: o.satoshis, lockingScript: LockingScript.fromHex(o.lockingScript) });
        tx.addOutput({ satoshis: 3_000, lockingScript: new P2PKH().lock(taker.toAddress()) });
        built = tx;
        return { signableTransaction: { tx: atomic(tx), reference: "ref-1" } };
      },
      async signAction(args: any) {
        signed = args;
        for (const [n, s] of Object.entries(args.spends) as [string, any][]) built!.inputs[Number(n)]!.unlockingScript = UnlockingScript.fromHex(s.unlockingScript);
        return { txid: built!.id("hex"), tx: atomic(built!) };
      },
    };
    seed = 100;
    const m = await moveBack({ wallet: wallet as any, base: "https://ex.test/amm", tokenId: TOKEN_ID, meta: { sym: "TST" }, submit: async (topic, beef) => { submits.push({ topic, in: hex(beef), out: hex(submissionBeef(topic, beef)) }); return { steak: { [topic]: { outputsToAdmit: [0], coinsToRetain: [], coinsRemoved: [] } } }; } });
    out.moveBackTokens.push({
      name,
      tokenRows: tokenRows.map((r, n) => ({ hex: w.held.find((t) => t.id("hex") === r.txid)!.toHex(), keyID: r.keyID, amount: String(r.amount), order: n === 1 ? `${"ab".repeat(32)}.3` : null })),
      satsRows: satsRows.map((r) => ({ hex: w.held.find((t) => t.id("hex") === r.txid)!.toHex(), keyID: r.keyID, satoshis: r.satoshis })),
      args: { ...big(created), inputBEEF: undefined }, spends: Object.keys(signed.spends), submits,
      result: big({ amount: m.amount, submitted: m.submitted, errors: m.errors }),
    });
  }
  let none = "";
  try { await moveBack({ wallet: fakeWallet().wallet, base: "https://ex.test/amm", tokenId: TOKEN_ID, meta: { sym: "TST" } }); } catch (e) { none = (e as Error).message; }
  out.moveBackNothing = none;
}

// The staged token outputs the basket lacks (`unfiledStagedTokens`) and their filing (`fileStagedToken`).
{
  const w = fakeWallet();
  const tokenScript = tokenP2pkhScript(TOKEN_ID, 50_000n, w.side.publicKey({ protocolID: SWAP_PROTOCOL, keyID: "amm-swap-0a1b", counterparty: "self", forSelf: true } as any));
  const actions = [
    { txid: "a1".repeat(32), outputs: [
      { outputIndex: 0, satoshis: 1, lockingScript: tokenScript, outputDescription: swapKeyDescription("TST for a swap", "amm-swap-0a1b"), basket: "" },
      { outputIndex: 1, satoshis: 2_000, lockingScript: "76a914" + "11".repeat(20) + "88ac", outputDescription: "Sats for a TST swap", basket: "amm-swap" },
    ] },
    { txid: "b2".repeat(32), outputs: [{ outputIndex: 0, satoshis: 1, lockingScript: tokenScript, outputDescription: swapKeyDescription("TST for a swap", "amm-swap-0a1b"), basket: "amm-swap" }] },
    { txid: "c3".repeat(32), outputs: [
      { outputIndex: 2, satoshis: 1, lockingScript: tokenScript, outputDescription: "x · amm-swap abc", basket: "" },
      { outputIndex: 3, satoshis: 5, lockingScript: "76a914" + "11".repeat(20) + "88ac", outputDescription: "x · amm-swap 0a1b", basket: "" },
      { outputIndex: 4, satoshis: 1, lockingScript: tokenScript, outputDescription: "TST for a swap", basket: "" },
    ] },
  ];
  let asked: any;
  const lister = { ...w.wallet, async listActions(a: any) { asked = a; return { totalActions: actions.length, actions }; } };
  const unfiled = await unfiledStagedTokens(lister as any);
  const filed: any[] = [];
  const filer = { ...w.wallet, async internalizeAction(a: any) { filed.push(a); return { accepted: true }; } };
  const ok = await fileStagedToken(filer as any, unfiled[0]!, [1, 2, 3]);
  const refused = await unfiledStagedTokens({ ...w.wallet, async listActions() { throw new Error("no"); } } as any);
  out.unfiled = { asked, actions, unfiled: big(unfiled), file: { accepted: ok, description: filed[0].description, labels: filed[0].labels, outputs: filed[0].outputs }, refused: big(refused) };
}

// The page's submit at the host root (`submitToOverlay`): its request and its answers; `steakText`.
{
  const subject = Beef.fromBinary(out.stageTokens.runs[0].submits[0].in.match(/../g).map((x: string) => parseInt(x, 16)));
  const bytes = subject.toBinaryAtomic(subject.atomicTxid!);
  const topic = `tm_color_${TOKEN_ID}`;
  const answers: [number, string][] = [
    [200, JSON.stringify({ [topic]: { outputsToAdmit: [0, 2], coinsToRetain: [], coinsRemoved: [] }, tm_other: { outputsToAdmit: [], coinsToRetain: [], coinsRemoved: [] } })],
    [200, JSON.stringify({ [topic]: { outputsToAdmit: [], coinsToRetain: [], coinsRemoved: [] } })],
    [503, "no steak yet"],
    [500, "down"],
    [200, "not json"],
    [200, "[1]"],
  ];
  const runs: any[] = [];
  for (const [status, text] of answers) {
    let req: any;
    let result: any;
    try {
      const r = await submitToOverlay("https://ex.test/@x/amm", topic, bytes, async (url: string, init: any) => { req = { url, method: init.method, headers: init.headers, body: hex(Array.from(init.body)) }; return { status, ok: status >= 200 && status < 300, text: async () => text } as any; });
      result = { text: steakText(r) };
    } catch (e) {
      result = { error: (e as Error).message };
    }
    runs.push({ status, answer: text, request: req, ...result });
  }
  out.submit = { topic, bytes: hex(bytes), runs, other: { topic: "tm_other", out: hex(submissionBeef("tm_other", bytes)) } };
}

// executeSwap's split buy (the Swift fee top-up test): 80,000 sats over pool_deploy and a smaller pool, whose
// first leg is 53,333 into pool_deploy (not the last), its row exactly that leg's need, and a second row 30
// sats short of what the next leg (the other 26,667 into pool_deploy) needs with that row alone.
{
  const commissionPkh = deriveCommissionPkh(v.identity, { txid: deployTxid, vout: 0 });
  const pool = stateOf(poolDeploy, v.identity);
  const needOf = (leg: Leg) => selectLegInputs({ wallet: fakeWallet().wallet, tokenId: TOKEN_ID, meta: { sym: "TST", dec: 0 }, direction: "bsvToToken", leg, pool, poolOutput: { beef: atomic(poolDeploy), outputIndex: 0 }, commissionPkh, satsPerKb: RATE }, [probe], [])!.need;
  const second = legFor(pool, 26_667n);
  const need1 = needOf(legFor(pool, 53_333n));
  const need2 = needOf(second);
  const first = await satsIn("a split buy's first leg", { commissionPkh, amountIn: 53_333n, extra: [0, need2.need - 30 - need1.need] });
  out.topUp = { ...first.out, second: big(second), secondNeed: big(need2) };
}

console.log(JSON.stringify(out, null, 1));
