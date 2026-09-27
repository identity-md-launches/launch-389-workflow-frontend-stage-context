# Whale Tax frontend

A single static Vite / React / TypeScript page for the deployed WHAL–ETH Uniswap v4 pool on Sepolia. Production files are supplied in `../dist/`; no backend or deployment transaction is needed.

## Run and rebuild

Use Node 22.12+ (validated with Node 24.21.0) and npm. From the repository root:

```sh
npm ci --prefix web --cache web/.cache/npm
npm run typecheck --prefix web
npm run build --prefix web
npm run preview --prefix web
```

Open the URL printed by Vite. `npm run dev --prefix web` first builds the deployment assets, then starts Vite with hot reload. Its middleware serves the same generated `dist/imd-deployment.json`. Production hosting only needs the complete `dist/` directory. `base: './'`, relative asset fetches, and one page work below a gateway subpath without rewrites. Serve over HTTPS (localhost is also a secure browser context) for Web Crypto integrity checks and wallet access.

Build order is deliberate:

1. `scripts/prepare.mjs` reads `docs/abi/<Contract>.json` with `git show` at the handoff's exact `sourceCommit`, checks equality with the preserved working ABI, and verifies canonical Keccak hashes. Object keys are recursively sorted, array ordering preserved, and compact UTF-8 JSON hashed with Keccak-256, without the `0x` prefix.
2. It exports those raw ABI arrays, creates the small Uniswap interface ABI, and compiles the simulation-only lens using pinned solc 0.8.26 / Cancun.
3. Vite replaces the root `dist/` with the static export.
4. `scripts/manifest.mjs` runs last, inventories **every** exported file except the manifest, calculates lowercase SHA-256 hashes, and writes `dist/imd-deployment.json`.

Rebuild the whole export after any source or runtime-asset edit. Never edit the generated export alone. The pinned source commit must remain available in Git to rebuild; the supplied export needs no Git or build tools to serve.

## Configuration and deployment binding

`config/deployment.json` and `config/network.json` preserve the supplied handoffs so builds continue after `.imd/reads/` is removed. `config/integrations.json` records the published PoolSwapTest router and the nondeployed simulation address. These are build inputs. The browser reads **only** `dist/imd-deployment.json` for chain, contract addresses, RPCs, pool parameters, ABI paths, and integrations. It fetches ABI/lens assets from that manifest, checks their SHA-256 hashes, and verifies the implementation ABIs' canonical Keccak bindings. No alternate chain/address/ABI map is bundled into JavaScript.

The network object and exact wallet-add-chain parameters are copied unchanged. There are no API keys, private credentials, or WalletConnect IDs. Injected EIP-1193 browser wallets are supported; remote WalletConnect sessions are not configured. Signing stays in the visitor's wallet. Reads try the supplied public RPCs and can fall back to an already-connected wallet **only** on the attested chain. Account/network/disconnect events invalidate previews. Unknown-chain switch errors trigger the exact `wallet_addEthereumChain` handoff, then retry switching.

Before enabling previews and before each transaction, the app verifies RPC chain ID, nonempty code for both contracts, PoolManager, StateView, Quoter and PoolSwapTest, and the hook/router's PoolManager bindings. This is runtime consistency checking, not a bytecode audit or independent proof of the attestation. The publication service validates the handoff and asset binding separately.

### Requirement conflicts resolved within the write scope

- Root `DESIGN.md` is outside the explicitly overriding permitted paths. The implemented design document is `docs/DESIGN.md`; no root file was added.
- The approved workflow explicitly requires **PoolSwapTest**. The supplied network block lists UniversalRouter, Quoter, StateView, PoolManager, PositionManager and Permit2, but omits PoolSwapTest. Altering that block would violate the exact-copy acceptance rule. The block stays unchanged; the same runtime manifest adds `integrations.poolSwapTest`, sourced from [Uniswap's official deployment table](https://developers.uniswap.org/docs/protocols/v4/deployments). All swaps and WHAL approvals use that single router entry. Quote and read calls use the supplied network's Quoter, StateView and PoolManager. No UniversalRouter/Permit2 approval flow is used because it would not implement the specifically assigned PoolSwapTest flow.
- `web/.gitignore` is the sole changed ignore file, with an explicit 1,024-byte maximum budget (actual size 210 bytes). Recursive patterns exclude dependencies, caches, test outputs and npm archives at every nesting level under the only frontend source root.

## Swap and preview behavior

Only exact-input buy/sell is exposed. The contract also supports exact-output internally, but the page does not promise an exact-output user flow.

`src/chain.ts` computes the pool ID from the attested native-ETH/WHAL key. StateView supplies the square-root price, tick, LP fee and active liquidity. The hook supplies the fee curve checkpoints, fee counters, and ERC-6909 claims. Recent `WhaleTax` events are filtered to this pool; `FeesBurned` events are filtered to ETH and WHAL. The last 500 blocks / latest 12 relevant events are shown; this is not full-history indexing. Reads refresh every 30 seconds and on request. Hook balances aggregate all native-ETH pools using this hook.

`simulation/PreviewLens.sol` is **never deployed or sent as a transaction**. The browser supplies its compiled runtime at an empty virtual address via an `eth_call` code state override. It calls the configured PoolManager's `unlock` and `swap`, reads StateView before and after the swap, queries the deployed hook's price-move and fee views, and observes the actual change in accrued claims. Its callback then reverts with a result payload. The outer call decodes that payload; all swap state is rolled back before settlement. No liquidity, token balance, token storage, hook storage or pool price is overridden. The hook ignores sender/hookData, making the different preview caller appropriate for this specific implementation. This technique must be reassessed for any different hook.

The app independently calls the supplied Uniswap Quoter at the same block and requires identical net output. It rejects zero output, no executed input and partial-input previews. Preview failure, including an RPC without code-override support, disables the confirmation step; no made-up estimated fee is substituted. Quotes expire after 60 seconds and reset on input, direction, tolerance, account, chain, and confirmed transactions.

A buy sends ETH directly to PoolSwapTest and needs no approval. A sell first approves exactly the typed WHAL amount to PoolSwapTest, waits for confirmation, and requires a new preview before the sell. Both router test settings are false (ordinary currency settlement/output, not ERC-6909 claims). Each real action is independently simulated with `eth_call`, gas-estimated, and account/chain-checked again before requesting `eth_sendTransaction` from the wallet.

**PoolSwapTest has a square-root price limit, not an amountOutMinimum or deadline.** The tolerance sets a worst pool price beyond the previewed endpoint using integer square-root math. The UI shows that price and explicitly explains that partial fills/refunds are possible and received output is not guaranteed. A preview's full fill is not a guarantee that a mined transaction will fully fill. Quotes and network fees may change before inclusion. This test router is used because the assignment specifically requests it.

Other controls: permissionless `burnFees` for either currency, standard WHAL transfer, and router allowance revocation. Burning requires an explicit consequence acknowledgment. Claims are transferred to the dead address; underlying currency is not withdrawn and token supply is not reduced. There are no owner/admin controls. PoolManager-only callbacks, ERC-20 delegated `transferFrom`, and pure diagnostic methods are not offered as arbitrary transaction buttons.

## Validation

```sh
npm test --prefix web
npm run typecheck --prefix web
npm run build --prefix web
npm run check:export --prefix web
npm run check:live --prefix web
npm run test:browser --prefix web
```

Browser tests use Playwright Chromium. On a new machine install the matching browser, for example from `web/`:

```sh
PLAYWRIGHT_BROWSERS_PATH=.cache/ms-playwright npx playwright install chromium
PLAYWRIGHT_BROWSERS_PATH=.cache/ms-playwright npm run test:browser
```

Alternatively set `PLAYWRIGHT_CHROMIUM_EXECUTABLE` to an existing compatible Chromium executable. The worker used its preinstalled Chromium headless shell. Tests intercept the production export at `https://whale.test/preview/`; no request to that domain leaves the browser. They exercise the actual bundled app, ABI encoding/decoding, manifest checks, and simulated wallet/RPC behavior. All wallet sends are intercepted. `check:live` performs public RPC reads and ephemeral `eth_call` simulations only; it never signs or broadcasts.

See `../docs/VALIDATION.md` and `../docs/evidence/` for actual checks, screenshots, findings and limitations. Publisher IPFS pinning, naming, public URLs and immutable asset checks are later service work; they are not claimed here.
