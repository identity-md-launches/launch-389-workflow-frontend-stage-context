# Frontend validation

Worker report dated 2026-09-27. This is local evidence, not independent workflow certification.

## Scope and requirement decisions

Implemented one static page for the attested WHAL–ETH pool: injected-wallet connection, switch/add chain, public/wallet read fallback, StateView price and liquidity, hook views and recent events, typed exact-input buy/sell simulation, fee curve, explicit token approval, PoolSwapTest swaps, permissionless fee-claim burning, transfer and allowance revocation. Source/config/lockfile are under `web/`, production under `dist/`, documentation under `docs/` and `web/`. Deployed Solidity, Foundry settings, libraries and root configuration were preserved.

The overriding write scope disallows a root `DESIGN.md`; the complete design record is [DESIGN.md](DESIGN.md). The supplied exact-copy network block omits the specifically requested PoolSwapTest router. It remains unchanged; an `integrations.poolSwapTest` entry in the same deployment manifest supplies Uniswap's published Sepolia test router. Reads and independent quotes use the handoff network addresses. See [README requirement decisions](../web/README.md#requirement-conflicts-resolved-within-the-write-scope).

Assumptions: one English light-theme page, browser-wallet support without a WalletConnect service ID, exact-input trading, native ETH/WHAL only, and bounded recent activity. There are no administration operations to expose. Contract callbacks and delegated ERC-20 `transferFrom` are not presented as end-user actions. No liquidity controls or new on-chain deployments were added.

## Executed checks

| Check | Actual outcome |
| --- | --- |
| `npm install --prefix web --cache web/.cache/npm --no-audit --no-fund` | Installed pinned frontend packages; npm lockfile included. Prettier added as pinned development dependency. No package/cache directory included in submission. |
| `npm run typecheck --prefix web` | Passed, exit 0, TypeScript strict/noEmit. |
| `npm run build --prefix web` | Passed, exit 0. Both implementation ABI canonical Keccak hashes match the handoff and pinned Git source. solc builds only the ephemeral lens. Vite 7.1.12 emitted the export; manifest emitted last. |
| `npm test --prefix web` | 9 passed, 0 failed. Covers amount validity/precision, fee boundaries, integer price-limit math/clamps, signed packed deltas, asset path safety, switch/add chain behavior, rejection, account/expiry gates and wallet fallback chain binding. |
| `npm run test:browser --prefix web` with `PLAYWRIGHT_CHROMIUM_EXECUTABLE` pointing to the preinstalled headless shell | 22 check groups passed. Actual production JS/CSS/HTML/ABI/lens bytes run in Chromium under `/preview/`. All wallet sends intercepted. [Machine-readable results](evidence/browser.json). |
| `npm run check:export --prefix web` | Passed, exit 0. 7 assets, 319,063 asset bytes; full inventory equals actual files; SHA-256 hashes, exact handoff fields/contract set, network and wallet-add-chain objects, and canonical ABI bindings match. Manifest is excluded from its own inventory. Every asset is below 8 MiB and count is below 128. |
| `npm run check:live --prefix web` | Passed, exit 0. Real Sepolia chain ID, code and read-only state/quote results recorded in [live-chain.json](evidence/live-chain.json). No transaction broadcast. |
| Protected-path diff and new-file scope check | Passed: no changes to deployed source, libraries, root configuration or other protected paths. All new deliverable paths are under `web/`, `dist/` or `docs/`. `web/.gitignore` is 210 bytes within its explicit 1,024-byte budget. |

The browser harness serves exact final export bytes through Playwright request fulfillment at `https://whale.test/preview/`. This domain is synthetic and receives no network requests. The supplied browser tool's loopback preview returned HTTP 403; local Chromium loopback navigation returned `ERR_ACCESS_DENIED`. An additional direct-browser public-RPC attempt returned `ERR_INTERNET_DISCONNECTED` for all configured endpoints; [live-browser.json](evidence/live-browser.json) records this limitation. Shell/Node RPC access did work. These environment limitations were not mislabeled as successful public-hosting or live-browser tests.

Browser scenarios include: disconnected reads/events; typed buy fee/output/price preview; wrong chain and exact unknown-chain add parameters; simulated buy and receipt; exact-amount approval and sell; consent-gated burn and receipt; WHAL transfer; allowance revocation; focused invalid input; account-change invalidation; 60-second expiry; absent wallet; user refusal; missing router code; unavailable quote/RPC; tampered ABI hash; failed router preflight; actual wallet transaction rejection; and a keyboard-only amount → tolerance → preview → connect → confirm buy flow. No application console errors or local resource failures occurred in the controlled browser suite. The separately attempted real browser RPC connection failed as described above.

## Live read-only evidence

At Sepolia block **11791753**, all six required deployed addresses had nonempty code: WHAL 1,753 bytes, hook 6,200, PoolManager 24,009, StateView 3,531, Quoter 5,820 and PoolSwapTest 6,950. Hook and router reported the configured PoolManager. Token decimals/symbol/supply and the fee checkpoints 30/265/500 bps matched the approved implementation. All fee counters were zero; no recent hook events were found.

A real ephemeral `eth_call` simulation for **0.001 ETH** produced approximately **49,269.770139 WHAL** net output, a **45 bps** price move and **72 bps** hook fee (approximately **357.315013 WHAL**). The configured Uniswap Quoter returned identical net output at the same block. The pool reported zero active liquidity at its starting tick; the successful buy crosses into the one-sided liquidity range, so the app correctly does not disable all swaps based solely on the current active-liquidity field.

A real **100 WHAL sell** preview returned no executable liquidity. The app reports this state and offers no confirmation. Successful sell/approval/burn/transfer/receipt interactions were validated with mocks. No funded wallet signing, actual swap, allowance change, claim burn or transfer was broadcast. No claim is made about future liquidity or eventual transaction inclusion.

## Better Interface review

Read the pinned workflow and core principles of accessibility, layout, writing, typography, colors and UI before implementation, then reviewed source, browser states and screenshots. Findings were corrected in source and rechecked against the rebuilt export.

| Domain | Coverage and evidence | Limitations |
| --- | --- | --- |
| Accessibility — Checked | Native controls/labels, skip link and landmarks; keyboard-only primary trade; named disclosures/table; focused amount errors; live progress/alerts; consent for permanent claim burn; visible focus screenshot; axe WCAG 2 A/AA and 2.1 AA checks at four widths returned zero violations. | No screen-reader session, physical device, native browser zoom or comprehensive WCAG certification. Forced-colors rules reviewed in source only. |
| Layout — Checked | Final screenshots inspected at 1440, 820, 390 and 320 CSS pixels; no document overflow; fields/actions remain reachable; disclosures preserve reading order; large identifiers wrap. 200% text enlargement retains reflow. | Text enlargement is not native 200% browser zoom. RTL and localization were not requested or tested. |
| Writing — Checked | Distinguishes hook fee/output from LP fee/input; explicitly states PoolSwapTest's price-limit/partial-fill behavior; exact approval steps; burn consequence and supply distinction; actionable recovery text and bounded event window. | External wallet wording belongs to the wallet. |
| Typography — Checked | System font stack, tabular figures, bounded headline, larger captions, persistent labels, mobile inputs at 16px+, readable plot/text equivalents inspected. | Installed system font/weights vary. No assertion that Inter was installed. Chart annotations scale with the SVG; checkpoint values are also in accessible text and prose. |
| Colors — Checked | Measured actual rendered pairs below; controlled axe contrast checks; noncolor status cues; no external background assets. | No dark mode exists. OS-native controls, forced-colors rendering and every possible focus adjacency were not exhaustively measured. |
| UI — Checked | Hover/source states, pressed direction, disabled/loading/ready/expired/error/empty states, surfaces and focus inspected; reduced-motion mode exercised. | Animations and overlays are not applicable. No animation-timeline or native-device session. |

Measured WCAG contrast ratios from browser-computed foreground and actual opaque background:

- Primary button: `#fffef9` / `#163e38`: **11.68:1**.
- Secondary lead copy: `#586c63` / `#f5f4ed`: **5.09:1**.
- Price-limit warning: `#794214` / `#fffef9`: **7.99:1**.
- Network label: `#163e38` / `#f5f4ed`: **10.70:1**.

### Findings and fixes

| Severity/domain | Final source location | Reproduction / impact | Fix and recheck |
| --- | --- | --- | --- |
| Medium — typography | `web/src/styles.css:325`, `:502`, `:967`; `web/src/App.tsx:39` | Initial 320px screenshot made captions and chart labels too small, including the consequential router warning. | Raised compact copy to 12px, enlarged narrow chart annotations, and moved the plot origin to make space. Final 320/390/820/1440 screenshots inspected; no page overflow. |
| Medium — layout | `web/src/styles.css:974` | Larger caption sizes crowded the narrow header. | Header/wallet controls wrap at 24rem. Final 320px screenshot inspected, controls remain accessible. |
| Medium — writing/recovery | `web/src/chain.ts:135` | Test sequence: connected wallet, router simulation reverts on all public RPCs, wallet fallback also refuses `eth_call`. Fallback error hid the useful original revert. | Preserve the public simulation failure if fallback fails. Browser `swapFail` scenario passes and confirms zero wallet transactions. |
| Medium — accessibility | `web/src/App.tsx:310`, `:525`, `:718` | Invalid amount/tolerance previously lacked a fully connected error/focus path. | Validate before preview RPC, focus amount/tolerance, reference the action error. Invalid-amount browser and keyboard-flow tests pass. |
| Low — UI hierarchy | `web/src/App.tsx:643` | Disconnected ready preview left both actions outlined, obscuring the next step. | Wallet connection takes filled emphasis after a valid preview; confirmation/approval take it when applicable. Final screenshots and keyboard focus inspected. |
| Low — observability | `web/src/chain.ts:256` | A currency burn for another pool could otherwise be labeled ETH in this page's bounded event list. | Filter burn currencies to native ETH and WHAL and swap events to the attested pool. Mock unrelated pool log is excluded. |

Screenshots: [desktop 1440](evidence/desktop-1440.png), [intermediate 820](evidence/desktop-820.png), [mobile 390](evidence/desktop-390.png), [reflow 320](evidence/desktop-320.png), [200% text](evidence/text-200.png), [keyboard focus](evidence/keyboard-focus.png). Market/account data in these screenshots is deliberately mocked and is not historical chain evidence.

## Completion and remaining limits

Complete for the assigned frontend source/export and worker validation scope, with the two explicit path/network requirement resolutions above. Build, typecheck, actual rendered browser/interaction checks and read-only live RPC checks ran. Hosted-browser RPC/CORS behavior and real wallet transactions remain unverified due to the worker browser's offline network environment and the deliberate no-broadcast validation scope. Exact-output trading, full-history indexing, mobile wallet deep links and WalletConnect are not implemented.

The deployment manifest is the runtime configuration and was emitted after the final application build. No publisher, IPFS, named URL/CID or control-plane HTTP/RPC publication check was run or claimed. This assignment is source delivery, not publication or contract deployment.

## Git delivery limitation

The workspace mounts `.git` read-only. `git add -- web dist docs` failed with `Unable to create .git/index.lock: Read-only file system`, so the worker could not stage or commit in the original checkout. Source/export/evidence remain ready for the assignment collector. A temporary Git clone in the disposable `test/scratch/` area is used to check a complete candidate submission bundle against the 8 MiB budget; no nested repository or bundle is included in the delivered tree.

Final size check: a complete candidate Git bundle (all refs/history plus the frontend commit in that disposable clone) measured about **2.0 MiB**, comfortably below **8 MiB**. Final scope checks found no changed path outside `web/`, `dist/` and `docs/`, no Git submodule entries, and no dependency/cache/archive directories in the candidate commit. The temporary commit is validation scaffolding only; the original checkout remains uncommitted because of its read-only Git metadata.
