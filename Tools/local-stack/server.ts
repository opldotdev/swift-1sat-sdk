// The local stack for the Swift live tests (ONESAT_LIVE=local).
//
// Wallet storage is the real thing: `createStorageServer` from `@1sat/wallet-server`, which runs
// the `@bsv/wallet-toolbox` StorageServer behind `@bsv/auth-express-middleware`, over toolbox
// `StorageKnex` (production runs it on Postgres) on sqlite3. Only the chain is fake, and nothing
// here reaches the network:
//
// - Chain services are a stub: every merkle root is valid, every broadcast succeeds and is kept.
// - A minimal 1sat-stack read API is served from what was broadcast or paid by the faucet, so the
//   SDK's own clients (owner sync, BEEF, chain tip) run unchanged against it.
// - A faucet pays any address from a made-up proven transaction.
// - A logging proxy in front of storage records every call: HTTP method, path, JSON-RPC method,
//   request bytes, JSON node count, longest array, binary request encoding, status, and whether
//   the reply was signed. Tests read it back from GET /__stack/calls.
//
//   bun run server.ts
//
// Environment: LOCAL_STACK_PORT (18199), LOCAL_STACK_STORAGE_PORT (18198), LOCAL_STACK_DIR (a new
// temp dir), LOCAL_STACK_CHAIN (test | main, default test), NO_BATCH=1 (storage without action
// batches, so SIGMA goes through createAction/processAction).
import { appendFileSync, mkdirSync, mkdtempSync } from 'node:fs'
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http'
import { tmpdir } from 'node:os'
import { createRequire } from 'node:module'
import { join } from 'node:path'
import { createStorageServer } from '@1sat/wallet-server'
import {
	Beef,
	Hash,
	MerklePath,
	P2PKH,
	PrivateKey,
	ProtoWallet,
	Script,
	Transaction,
	Utils,
} from '@bsv/sdk'
import { StorageKnex, StorageProvider, type Wallet } from '@bsv/wallet-toolbox'
import knexLib from 'knex'

/** `@bsv/sdk` as the toolbox loads it (CommonJS), for values handed to the toolbox. */
const ToolboxSdk = createRequire(import.meta.url)('@bsv/sdk') as typeof import('@bsv/sdk')

type Chain = 'main' | 'test'

const chain = (process.env.LOCAL_STACK_CHAIN ?? 'test') as Chain
if (chain !== 'main' && chain !== 'test') {
	throw new Error(`LOCAL_STACK_CHAIN must be main or test, not ${chain}`)
}
const PORT = Number(process.env.LOCAL_STACK_PORT ?? 18199)
const STORAGE_PORT = Number(process.env.LOCAL_STACK_STORAGE_PORT ?? 18198)
const dir = process.env.LOCAL_STACK_DIR ?? mkdtempSync(join(tmpdir(), 'onesat-local-stack-'))
mkdirSync(dir, { recursive: true })
const callsLog = join(dir, 'calls.log')
const addressPrefix = chain === 'main' ? [0x00] : [0x6f]

// --- chain stub ---------------------------------------------------------------------------------

/** Every transaction the stub has seen: faucet payments (proven) and broadcasts (unproven). */
const ledger = new Beef()
/** Height reported as the tip. Faucet transactions are proven at heights below it. */
const TIP = 900_100
let faucetHeight = 900_000
let sequence = 0

interface IndexedOutput {
	txid: string
	vout: number
	satoshis: number
	score: number
	spendTxid?: string
}
/** Address -> outputs that pay it (P2PKH, or a script ending in P2PKH such as an inscription). */
const byOwner = new Map<string, IndexedOutput[]>()
const byOutpoint = new Map<string, IndexedOutput>()
const broadcasts: string[] = []
/** Merkle root of each height the faucet proved a transaction at. */
const rootsByHeight = new Map<number, string>()

// OP_DUP OP_HASH160 <20 bytes> OP_EQUALVERIFY OP_CHECKSIG
function isP2PKH(b: number[]): boolean {
	return b.length === 25 && b[0] === 0x76 && b[1] === 0xa9 && b[2] === 0x14 && b[23] === 0x88 && b[24] === 0xac
}

/**
 * The address a script pays: a bare P2PKH, a P2PKH followed by an inscription envelope (the 1Sat
 * layout), or an envelope ending in OP_ENDIF followed by a P2PKH. Anything else is not indexed.
 */
function ownerOf(script: Script): string | undefined {
	const bytes = script.toBinary()
	if (bytes.length < 25) return undefined
	const head = bytes.slice(0, 25)
	const tail = bytes.slice(bytes.length - 25)
	let hash: number[] | undefined
	if (isP2PKH(head) && (bytes.length === 25 || bytes[25] === 0x00)) hash = head.slice(3, 23)
	else if (isP2PKH(tail) && bytes[bytes.length - 26] === 0x68) hash = tail.slice(3, 23)
	return hash ? Utils.toBase58Check(hash, addressPrefix) : undefined
}

function index(tx: Transaction): void {
	const txid = tx.id('hex')
	if (byOutpoint.has(`${txid}.0`)) return
	sequence += 1
	const score = TIP + sequence / 1_000_000
	for (const input of tx.inputs) {
		const source = input.sourceTXID ?? input.sourceTransaction?.id('hex')
		const spent = byOutpoint.get(`${source}.${input.sourceOutputIndex}`)
		if (spent) spent.spendTxid = txid
	}
	tx.outputs.forEach((output, vout) => {
		const entry: IndexedOutput = { txid, vout, satoshis: output.satoshis ?? 0, score }
		byOutpoint.set(`${txid}.${vout}`, entry)
		const owner = ownerOf(output.lockingScript)
		if (owner) byOwner.set(owner, [...(byOwner.get(owner) ?? []), entry])
	})
}

/**
 * Merges a BEEF into the ledger and indexes `txids` with their unproven ancestors. Takes bytes:
 * the toolbox loads `@bsv/sdk` as CommonJS and this file as ESM, so a `Beef` from one is not an
 * `instanceof Beef` in the other.
 */
function indexBeef(bytes: number[], txids: string[]): void {
	const beef = Beef.fromBinary(bytes)
	ledger.mergeBeef(bytes)
	for (const txid of txids) {
		const tx = beef.findAtomicTransaction(txid)
		if (!tx) throw new Error(`stub postBeef: BEEF has no transaction ${txid}`)
		// Ancestors first, so their spends are indexed before the subject's.
		const chainOf: Transaction[] = []
		const walk = (t: Transaction) => {
			for (const input of t.inputs) if (input.sourceTransaction) walk(input.sourceTransaction)
			chainOf.push(t)
		}
		walk(tx)
		for (const t of chainOf) index(t)
	}
}

const stubServices = {
	chain,
	async getChainTracker() {
		return { isValidRootForHeight: async () => true, currentHeight: async () => TIP }
	},
	async getHeight() {
		return TIP
	},
	/** An 80-byte header carrying the merkle root the stub proved at that height, if any. */
	async getHeaderForHeight(height: number): Promise<number[]> {
		const w = new Utils.Writer()
		w.writeUInt32LE(1)
		w.write(Hash.sha256(Utils.toArray(`block-${height - 1}`, 'utf8')))
		const root = rootsByHeight.get(height)
		w.write(root ? Utils.toArray(root, 'hex').reverse() : new Array(32).fill(0))
		w.writeUInt32LE(1_700_000_000 + height)
		w.writeUInt32LE(0x1d00ffff)
		w.writeUInt32LE(height)
		return w.toArray()
	},
	async postBeef(beef: { toBinary(): number[] }, txids: string[]) {
		indexBeef(beef.toBinary(), txids)
		broadcasts.push(...txids)
		console.log(`STUB postBeef ${txids.join(',')}`)
		return [
			{
				name: 'stub',
				status: 'success' as const,
				txidResults: txids.map((txid) => ({ txid, status: 'success' as const })),
			},
		]
	},
	async getStatusForTxids(txids: string[]) {
		return {
			name: 'stub',
			status: 'success' as const,
			results: txids.map((txid) => ({ txid, status: 'known' as const, depth: 0 })),
		}
	},
	async isUtxo() {
		return true
	},
	async nLockTimeIsFinal() {
		return true
	},
	async getBeefForTxid(txid: string) {
		const tx = ledger.findAtomicTransaction(txid)
		if (!tx) throw new Error(`stub: no BEEF for ${txid}`)
		// The toolbox's own (CommonJS) Beef, for the same reason as in indexBeef.
		return ToolboxSdk.Beef.fromBinary(tx.toBEEF())
	},
	async getRawTx(txid: string) {
		const tx = ledger.findTxid(txid)?.tx
		return tx ? { txid, name: 'stub', rawTx: tx.toBinary() } : { txid, name: 'stub' }
	},
	async getMerklePath() {
		return { name: 'stub' }
	},
	hashOutputScript(script: string) {
		return Utils.toHex(Hash.sha256(Utils.toArray(script, 'hex')).reverse())
	},
	getServicesCallHistory() {
		return {}
	},
}

// --- storage ------------------------------------------------------------------------------------

// The server identity signs BRC-104 responses, as the hosted server's key does.
const serverWallet = new ProtoWallet(PrivateKey.fromRandom())
const storageOptions = StorageProvider.createStorageBaseOptions(chain)
storageOptions.feeModel = { model: 'sat/kb', value: 100 }
const knex = knexLib({
	client: 'sqlite3',
	connection: { filename: join(dir, `storage-${chain}.db`) },
	useNullAsDefault: true,
})
const storage = new StorageKnex({ ...storageOptions, knex })
await storage.migrate('local stack', PrivateKey.fromRandom().toPublicKey().toString())
await storage.makeAvailable()
storage.setServices(stubServices as unknown as Parameters<typeof storage.setServices>[0])
if (process.env.NO_BATCH === '1') storage.supportsActionBatchPersistence = () => false
// The RPC layer answers only a public summary of a failure; log what storage itself threw.
for (const name of [
	'createAction',
	'processAction',
	'internalizeAction',
	'beginActionBatch',
	'commitActionBatch',
] as const) {
	const target = storage as unknown as Record<string, (...args: unknown[]) => Promise<unknown>>
	const fn = target[name]?.bind(storage)
	if (!fn) continue
	target[name] = async (...args: unknown[]) => {
		try {
			return await fn(...args)
		} catch (e) {
			const err = e as Error
			console.log(`STORAGE ${name} threw ${err?.name}: ${err?.message}\n${err?.stack ?? ''}`)
			throw e
		}
	}
}
const storageServer = createStorageServer({
	storage,
	wallet: serverWallet as unknown as Wallet,
	listen: { port: STORAGE_PORT, host: '127.0.0.1' },
})
storageServer.start()

// --- faucet -------------------------------------------------------------------------------------

/** Pays `satoshis` to `address` in a transaction with a made-up proof at its own height. */
function faucet(address: string, satoshis: number): string {
	const tx = new Transaction()
	tx.addInput({
		sourceTXID: Utils.toHex(PrivateKey.fromRandom().toArray()),
		sourceOutputIndex: 0,
		unlockingScript: Script.fromASM('OP_TRUE'),
		sequence: 0xffffffff,
	})
	tx.addOutput({ lockingScript: new P2PKH().lock(address), satoshis })
	const txid = tx.id('hex')
	faucetHeight += 1
	tx.merklePath = new MerklePath(faucetHeight, [[{ offset: 0, hash: txid, txid: true }]])
	rootsByHeight.set(faucetHeight, tx.merklePath.computeRoot(txid))
	const beef = new Beef()
	beef.mergeTransaction(tx)
	indexBeef(beef.toBinary(), [txid])
	console.log(`FAUCET ${satoshis} sats to ${address} in ${txid}`)
	return txid
}

// --- HTTP: stack API, faucet, call log, storage proxy ------------------------------------------

interface CallRecord {
	at: string
	identityKey: string | null
	httpMethod: string
	path: string
	rpc: string
	reqBytes: number
	jsonNodes: number
	longestArray: number
	binaryRequestEncoding: string | null
	binaryEncodingAsked: string | null
	binaryEncodingEchoed: string | null
	status: number
	signed: boolean
	resBytes: number
	/** The longest JSON array in the reply: bytes sent as number arrays show up here. */
	resLongestArray: number
	errorBody?: string
}
const calls: CallRecord[] = []

function send(res: ServerResponse, status: number, body: unknown, type = 'application/json'): void {
	const bytes =
		body instanceof Uint8Array ? body : Buffer.from(typeof body === 'string' ? body : JSON.stringify(body))
	res.writeHead(status, { 'content-type': type, 'content-length': String(bytes.length) })
	res.end(bytes)
}

async function readBody(req: IncomingMessage): Promise<Buffer> {
	const chunks: Buffer[] = []
	for await (const c of req) chunks.push(c as Buffer)
	return Buffer.concat(chunks)
}

function header(req: IncomingMessage, name: string): string | null {
	const v = req.headers[name.toLowerCase()]
	return Array.isArray(v) ? v.join(',') : (v ?? null)
}

async function proxy(req: IncomingMessage, res: ServerResponse, url: URL): Promise<void> {
	const body = await readBody(req)
	let rpc = '-'
	let jsonNodes = 0
	let longestArray = 0
	if (body.length > 0) {
		try {
			const parsed = JSON.parse(body.toString('utf8'))
			rpc = parsed?.method ?? '-'
			const walk = (v: unknown) => {
				jsonNodes++
				if (Array.isArray(v)) {
					if (v.length > longestArray) longestArray = v.length
					for (const x of v) walk(x)
				} else if (v && typeof v === 'object') for (const x of Object.values(v)) walk(x)
			}
			walk(parsed)
		} catch {
			rpc = '(not json)'
		}
	}
	const headers: Record<string, string> = {}
	for (const [k, v] of Object.entries(req.headers)) {
		if (k === 'content-length' || k === 'host' || v === undefined) continue
		headers[k] = Array.isArray(v) ? v.join(',') : v
	}
	const up = await fetch(`http://127.0.0.1:${STORAGE_PORT}${url.pathname}${url.search}`, {
		method: req.method,
		headers,
		body: req.method === 'GET' || req.method === 'HEAD' ? undefined : body,
	})
	const out = Buffer.from(await up.arrayBuffer())
	let resLongestArray = 0
	if (out.length > 0) {
		try {
			const walkOut = (v: unknown) => {
				if (Array.isArray(v)) {
					if (v.length > resLongestArray) resLongestArray = v.length
					for (const x of v) walkOut(x)
				} else if (v && typeof v === 'object') for (const x of Object.values(v)) walkOut(x)
			}
			walkOut(JSON.parse(out.toString('utf8')))
		} catch {
			// not JSON: nothing to measure
		}
	}
	const record: CallRecord = {
		at: new Date().toISOString(),
		identityKey: header(req, 'x-bsv-auth-identity-key'),
		httpMethod: req.method ?? '-',
		path: url.pathname,
		rpc,
		reqBytes: body.length,
		jsonNodes,
		longestArray,
		binaryRequestEncoding: header(req, 'x-bsv-binary-request-encoding'),
		binaryEncodingAsked: header(req, 'x-bsv-binary-encoding'),
		binaryEncodingEchoed: up.headers.get('x-bsv-binary-encoding'),
		status: up.status,
		signed: up.headers.get('x-bsv-auth-signature') != null,
		resBytes: out.length,
		resLongestArray,
	}
	if (up.status >= 400) record.errorBody = out.toString('utf8').slice(0, 2000)
	calls.push(record)
	const line = `${record.at} ${record.httpMethod} ${record.path} rpc=${rpc} reqBytes=${body.length} jsonNodes=${jsonNodes} longestArray=${longestArray} binReq=${record.binaryRequestEncoding ?? '-'} -> ${up.status} signed=${record.signed} resBytes=${out.length} resLongestArray=${resLongestArray}${record.errorBody ? ` body=${record.errorBody}` : ''}`
	console.log(line)
	appendFileSync(callsLog, `${line}\n`)
	const h: Record<string, string> = {}
	up.headers.forEach((v, k) => {
		if (k !== 'content-encoding' && k !== 'content-length' && k !== 'transfer-encoding') h[k] = v
	})
	res.writeHead(up.status, h)
	res.end(out)
}

async function route(req: IncomingMessage, res: ServerResponse): Promise<void> {
	const url = new URL(req.url ?? '/', `http://127.0.0.1:${PORT}`)
	const path = url.pathname

	if (req.method === 'GET' && path === '/__stack/health') {
		return send(res, 200, { ok: true, chain, storagePort: STORAGE_PORT, dir })
	}
	if (req.method === 'GET' && path === '/__stack/calls') {
		const identity = url.searchParams.get('identityKey')
		return send(res, 200, identity ? calls.filter((c) => c.identityKey === identity) : calls)
	}
	if (req.method === 'GET' && path === '/__stack/broadcasts') {
		return send(res, 200, broadcasts)
	}
	if (req.method === 'POST' && path === '/__stack/faucet') {
		const { address, satoshis } = JSON.parse((await readBody(req)).toString('utf8'))
		if (typeof address !== 'string' || !Number.isSafeInteger(satoshis) || satoshis <= 0) {
			return send(res, 400, { error: 'faucet takes { address: string, satoshis: positive integer }' })
		}
		return send(res, 200, { txid: faucet(address, satoshis) })
	}

	// The 1sat-stack read API, as the SDK's clients call it.
	if (req.method === 'GET' && path === '/1sat/chaintracks/tip') {
		const hash = Utils.toHex(Hash.sha256(Utils.toArray(`tip-${TIP}`, 'utf8')))
		return send(res, 200, { height: TIP, hash, merkleRoot: hash })
	}
	if (req.method === 'GET' && path === '/1sat/owner/sync') {
		const owners = url.searchParams.getAll('owner')
		const from = Number(url.searchParams.get('from') ?? '0')
		const rows = owners
			.flatMap((o) => byOwner.get(o) ?? [])
			.filter((o) => o.score > from)
			.sort((a, b) => a.score - b.score || a.vout - b.vout)
		const frames = rows.map(
			(o) =>
				`data: ${JSON.stringify({ outpoint: `${o.txid}_${o.vout}`, score: o.score, ...(o.spendTxid ? { spendTxid: o.spendTxid } : {}) })}\n\n`,
		)
		return send(res, 200, `${frames.join('')}event: done\ndata: {}\n\n`, 'text/event-stream')
	}
	const beefMatch = path.match(/^\/1sat\/beef\/([0-9a-f]{64})(\/tx)?$/)
	if (req.method === 'GET' && beefMatch) {
		const txid = beefMatch[1]
		if (beefMatch[2]) {
			const tx = ledger.findTxid(txid)?.tx
			if (!tx) return send(res, 404, { error: `no transaction ${txid}` })
			return send(res, 200, Uint8Array.from(tx.toBinary()), 'application/octet-stream')
		}
		const tx = ledger.findAtomicTransaction(txid)
		if (!tx) return send(res, 404, { error: `no BEEF for ${txid}` })
		return send(res, 200, Uint8Array.from(tx.toAtomicBEEF()), 'application/octet-stream')
	}
	if (path.startsWith('/1sat/') || path.startsWith('/__stack/')) {
		return send(res, 404, { error: `the local stack does not serve ${req.method} ${path}` })
	}
	return proxy(req, res, url)
}

createServer((req, res) => {
	route(req, res).catch((e: Error) => {
		console.log(`LOCAL STACK ${req.method} ${req.url} failed: ${e?.stack ?? e}`)
		if (!res.headersSent) send(res, 500, { error: String(e?.message ?? e) })
		else res.end()
	})
}).listen(PORT, '127.0.0.1', () => {
	console.log(`local stack (${chain}) on http://127.0.0.1:${PORT} -> storage :${STORAGE_PORT}, data in ${dir}`)
})
