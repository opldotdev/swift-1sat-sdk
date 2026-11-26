// Prints ordlock-list-vectors.json: what @1sat/actions builds for an OrdLock v2 listing, from the
// real `buildListOrdinal` and `sellOpns` (createAction captured, then refused) over a ProtoWallet
// for the ActionVectors identity. Run from packages/actions of a 1sat-sdk checkout (see ordlock-list-vectors.gen.sh).
import { PrivateKey, ProtoWallet } from '@bsv/sdk'
import { buildListOrdinal, defaultPayAddress, sellOrdinal } from './src/ordinals/index.ts'
import { sellOpns } from './src/opns/index.ts'

const IDENTITY = 'ffbd04ccf50e9822ac4387cc180d1a5021c16c89b288013fc8b9a2111dfa2da2'
const OUTPOINT = `${'aa'.repeat(32)}.0`
const PAY = '1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa'
const BEEF = [1, 2, 3]

function makeCtx(row: Record<string, unknown>, captured: { args?: unknown }) {
	const proto = new ProtoWallet(PrivateKey.fromHex(IDENTITY))
	const wallet = {
		getPublicKey: (a: any) => proto.getPublicKey(a),
		listOutputs: async () => ({ totalOutputs: 1, outputs: [row], BEEF }),
		createAction: async (args: unknown) => {
			captured.args = args
			throw new Error('captured')
		},
	}
	return { wallet, chain: 'main', isBaseWallet: true } as any
}

function ordinalRow(tags: string[], ci: Record<string, unknown>) {
	return {
		outpoint: OUTPOINT,
		satoshis: 1,
		spendable: true,
		tags,
		customInstructions: JSON.stringify(ci),
	}
}

const ci = { protocolID: [0, 'onesat'], keyID: OUTPOINT, counterparty: 'self' }

const cases: Record<string, unknown>[] = []

// The createAction args after the TS pipeline (`applyP1SatCreateAction`): the random action id in
// `id:` tags is replaced by `<actionId>` so the vector is stable.
function created(args: any) {
	const actionId = (args.outputs ?? [])
		.flatMap((o: any) => o.tags ?? [])
		.find((t: string) => t.startsWith('id:'))
		?.slice(3)
		.replace(/_\d+$/, '')
	return JSON.parse(
		JSON.stringify({
			description: args.description,
			labels: args.labels ?? [],
			inputs: args.inputs,
			outputs: args.outputs,
			randomizeOutputs: args.options?.randomizeOutputs,
		}).replaceAll(`id:${actionId}_`, 'id:<actionId>_'),
	)
}

async function ordinalCase(
	name: string,
	tags: string[],
	rowCi: Record<string, unknown>,
	request: { price: number; payAddress?: string; map?: Record<string, string> },
) {
	const ctx = makeCtx(ordinalRow(tags, rowCi), {})
	const built: any = await buildListOrdinal(ctx, { id: 'list_0', ...request })
	if ('error' in built) {
		cases.push({ name, family: 'ordinal', tags, customInstructions: JSON.stringify(rowCi), request, error: built.error })
		return
	}
	const captured: { args?: any } = {}
	await sellOrdinal.execute(makeCtx(ordinalRow(tags, rowCi), captured), { id: 'list_0', ...request })
	cases.push({
		name,
		family: 'ordinal',
		tags,
		customInstructions: JSON.stringify(rowCi),
		request,
		args: {
			description: built.description,
			labels: built.labels ?? [],
			inputs: built.inputs,
			outputs: built.outputs,
		},
		created: created(captured.args),
	})
}

async function opnsCase(
	name: string,
	tags: string[],
	rowCi: Record<string, unknown>,
	request: { price: number; payAddress?: string },
) {
	const captured: { args?: any } = {}
	const ctx = makeCtx(ordinalRow(tags, rowCi), captured)
	const result: any = await sellOpns.execute(ctx, { id: 'aa_0', ...request })
	const args = captured.args
	cases.push({
		name,
		family: 'opns',
		tags,
		customInstructions: JSON.stringify(rowCi),
		request,
		...(args ? { created: created(args) } : { error: result.error }),
	})
}

await ordinalCase(
	'ordinalDefaultPay',
	['type:image/png', `origin:${OUTPOINT}`, 'id:list_0'],
	{ ...ci, name: 'Pixel Ape' },
	{ price: 50_000 },
)
await ordinalCase(
	'ordinalMapAndPayAddress',
	['origin', 'type:image', 'type:image/png', `collection:${'bb'.repeat(32)}.0`, 'app:1sat', 'name:Legacy', 'id:list_0'],
	{ ...ci, name: 'Canonical Ape' },
	{ price: 21_000_000, payAddress: PAY, map: { app: '1sat', type: 'ord' } },
)
await ordinalCase('ordinalZeroPrice', ['type:image/png', 'id:list_0'], ci, { price: 0 })
await opnsCase(
	'opnsDefaultPay',
	['type:application/op-ns', `origin:${OUTPOINT}`, 'name:alice', 'id:aa_0'],
	ci,
	{ price: 1_234 },
)
await opnsCase(
	'opnsLongPricePublished',
	['opns', 'type:application/op-ns', `origin:${OUTPOINT}`, 'opns:published', 'id:aa_0'],
	{ ...ci, name: 'bob' },
	{ price: 2_100_000_000_000_000, payAddress: PAY },
)
await opnsCase('opnsZeroPrice', ['type:application/op-ns', 'id:aa_0'], ci, { price: 0 })

const ctx = makeCtx({}, {})
console.log(
	JSON.stringify(
		{
			source: '@1sat/actions buildListOrdinal and sellOpns (createAction args) over ProtoWallet',
			identity: IDENTITY,
			outpoint: OUTPOINT,
			defaultPayAddress: await defaultPayAddress(ctx),
			cases,
		},
		null,
		2,
	),
)
