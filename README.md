# Whale Tax (WHAL) and WhaleTaxHook

A Sepolia `univ4_hook` launch: a fixed-supply ERC-20 and a Uniswap v4 hook on its native-ETH pool
whose swap fee grows with the swap's own price impact.

| Piece                       | Where                                 |
| --------------------------- | ------------------------------------- |
| Token                       | `src/WhaleToken.sol`                  |
| Hook                        | `src/WhaleTaxHook.sol`                |
| Permission bits + miner     | `src/HookFlags.sol`, `src/HookMiner.sol` |
| Reference deploy script     | `script/DeployWhaleTax.s.sol`         |
| Tests                       | `test/` (see "Tests" below)           |
| ABIs                        | `docs/abi/WhaleTaxHook.json`, `docs/abi/WhaleToken.json` |
| Vendored dependencies       | `lib/` (commits recorded in `lib/VENDORED.md`) |

```
forge build
forge test
forge fmt --check
```

The toolchain is pinned in `foundry.toml`: `solc = "0.8.26"`, `evm_version = "cancun"` (the hook uses
transient storage), `bytecode_hash = "none"`, optimizer on at 200 runs, no `via_ir`, no `ffi`, no
filesystem permissions. Everything under `lib/` is committed as plain files so the build works offline.

## The token

`WhaleToken` is OpenZeppelin's ERC-20 with a zero-argument constructor that mints the entire
1,000,000,000 WHAL (18 decimals) to `msg.sender`, i.e. to the launch factory. There is no owner, no
mint, no burn, no pause, no upgrade path and no other admin surface. After construction it is a plain
ERC-20.

## The hook

### What it does

`WhaleTaxHook` serves the pool `(currency0 = native ETH, currency1 = WHAL, fee 3000, tickSpacing 60)`
and taxes each swap in proportion to the price move that swap causes:

1. `beforeSwap` reads the pool's `sqrtPriceX96` and stores it in a transient slot keyed by `PoolId`.
2. `afterSwap` reads the post-swap `sqrtPriceX96`, clears the slot, and computes the price move
   `m = |P_after / P_before - 1| x 10,000` with `P = sqrtPriceX96^2`, all through `FullMath.mulDiv`.
3. The fee rate is `feeBps = 30 + floor(470 x min(m, 500) / 500)`: 0.30% for a swap that barely
   moves the price, rising linearly to 5.00% at a 5% move, capped there.
4. The fee is `floor(unspecifiedLeg x feeBps / 10,000)` of the swap's **unspecified** leg and is
   returned as a positive unspecified `afterSwap` delta. Exact-in: it comes out of the output.
   Exact-out: it is added on top of the input. It is always in whichever currency that leg is.
5. The PoolManager credits the hook with the fee; the hook consumes the credit at once by minting
   itself ERC-6909 claims for that currency. The hook never calls `take()` and never holds tokens.
6. `burnFees(currency)` is permissionless. It moves every accrued claim of that currency to
   `0x000000000000000000000000000000000000dEaD` inside the hook's own `unlockCallback`. That is the
   only place claims can ever go; the caller receives nothing.
7. Every swap on a native-ETH pool emits `WhaleTax(poolId, moveBps, feeBps, currency, fee)`, fee or
   no fee. Burns emit `FeesBurned(currency, amount)`.

The permissions are exactly `beforeSwap`, `afterSwap` and `afterSwapReturnDelta` (address bits
`0x00C4`); all others are false. The constructor calls `Hooks.validateHookPermissions`, so the
contract can only exist at a CREATE2 address mined for those bits. The only constructor argument is
the PoolManager.

### Views

| View                                | Meaning                                                                |
| ----------------------------------- | ---------------------------------------------------------------------- |
| `feeBpsForMove(moveBps)`            | The fee curve.                                                         |
| `priceMoveBps(before, after)`       | The price-move formula, for previews.                                  |
| `feeAmount(leg, feeBps)`            | The fee for a leg at a rate.                                           |
| `accruedFees(currency)`             | Fees collected and not yet burned. Always equals `claimsOf(currency)`. |
| `claimsOf(currency)`                | The hook's ERC-6909 balance on the PoolManager.                        |
| `totalFeesCollected(currency)`      | Lifetime fees. Equals accrued + burned.                                |
| `totalFeesBurned(currency)`         | Lifetime claims sent to `DEAD`.                                        |
| `pendingPreSwapSqrtPriceX96(poolId)`| The transient pre-swap price; zero outside a swap.                     |
| `getHookPermissions()`              | The declared permissions.                                              |

### Design decisions and assumptions

- **The tax is per swap.** A trade split across several swaps, or across blocks, pays less than the
  same size in one swap, because each swap is taxed only on the impact it alone causes. That is the
  design, not a bug. The `test_threeSwapsSameDirectionInOneTransaction` test demonstrates it.
- **Asymmetric move formula.** `m` is defined relative to the pre-swap price, so a price doubling is
  10,000 bps while a halving is 5,000 bps, and a fall can never reach 10,000. A rise whose sqrt-price
  ratio is 2^64 or more (a price ratio of 2^128 or more) reports `MOVE_BPS_SATURATED`
  (`type(uint256).max`) in the event instead of a figure that would not fit; the fee is capped at
  500 bps long before that, so the fee never depends on it. Only a swap in a pool with no liquidity
  can produce such a jump.
- **Rounding.** The move is floored. It is formed from two `mulDiv`s with 32 extra fractional bits,
  so the second rounding can only change the result when the true value lies within 2^-32 bps of an
  integer. The fee amount is floored, so dust legs pay nothing.
- **Zero-liquidity swaps.** In a pool with no liquidity in the swap's direction (for example a sell
  before the first buy, when the pool holds no ETH), the swap jumps to its price limit and exchanges
  nothing. The hook reports the move, a 500 bps rate, and a zero fee. Nothing reverts.
- **Non-ETH pools.** The hook can be attached to any pool. A pool whose `currency0` is not native ETH
  gets zero deltas, no transient write, no event and no claims. A pool whose `currency0` is ETH and
  whose `currency1` is some other token is taxed just like the WHAL pool; fees are accounted per
  currency and all of them can only be burned.
- **No initialize or liquidity callbacks.** The hook declares none, so the PoolManager never calls it
  during the factory's `initialize` or its one-sided seed, and nothing in the hook can revert either.
- **hookData is ignored.** The hook needs no swapper identity, so it reads nothing from `hookData`.
  `hookData` is unauthenticated in v4 in any case; nothing here trusts it.
- **`burnFees` cannot run inside a swap.** It calls `PoolManager.unlock`, which reverts if the
  manager is already unlocked. Its `unlockCallback` is guarded by `msg.sender == PoolManager`, and the
  PoolManager only calls back the address that called `unlock`, so only the hook itself can reach it.
- **ETH claims at `DEAD` are ETH locked in the PoolManager forever.** That is the burn.
- **No admin.** There is no owner, setter, pause, upgrade, sweep, delegatecall or selfdestruct. Every
  rate is a source constant. If the fee curve needs to change, that is a new hook and a new pool.

### Rounding proof sketch for "fee never exceeds the leg"

`feeBps <= 500`, so `fee = floor(leg x feeBps / 10,000) <= leg / 20`. The fee is therefore always
at most 5% of the gross unspecified leg, and zero when the leg is under 20 wei. The returned delta
is `int128(fee)`, which cannot truncate because `fee` is at most 5% of an `int128` magnitude.
`testFuzz_feeNeverExceedsFivePercentOfTheLeg` and the swap-shape fuzz cover this.

## Deployment parameters

| Parameter                    | Value                                                                  |
| ---------------------------- | ---------------------------------------------------------------------- |
| Chain                        | Sepolia (11155111) only                                                |
| PoolManager                  | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` (the only hook constructor argument) |
| Hook permission bits         | `0x00C4` = beforeSwap (1<<7) + afterSwap (1<<6) + afterSwapReturnDelta (1<<2)     |
| Hook creation code           | `type(WhaleTaxHook).creationCode ++ abi.encode(poolManager)` (see `DeployWhaleTax.hookCreationCode`) |
| Hook salt                    | Mined by the deployer (the factory) against its own address for exactly the bits above. `HookMiner.find` shows how. A salt mined for one CREATE2 sender is not valid for another. |
| Token constructor            | None. Supply goes to the deployer.                                     |
| Pool key                     | `currency0 = 0x0 (ETH)`, `currency1 = WHAL`, `fee = 3000`, `tickSpacing = 60`, `hooks = the hook` |
| Initial price and seed       | Set by the manifest (`launch.json`, written by the manifest assignment). The tests rehearse with tick 154,200 (about 5,000,000 WHAL per ETH) and a 500,000,000 WHAL one-sided seed; those are placeholders, not the launch values. |
| Fee constants                | `BASE_FEE_BPS = 30`, `MAX_FEE_BPS = 500`, `MOVE_CAP_BPS = 500`, `DEAD = 0x…dEaD` |

The factory deploys both contracts, initializes the pool at the manifest price, and seeds one-sided
WHAL liquidity in the range below the current tick, so the first buy lands in a pool that holds no ETH.
`test/LaunchRehearsal.t.sol` replays that sequence against a real `PoolManager`.

`script/DeployWhaleTax.s.sol` is the reviewable reference for the same shape and a manual fallback.
Its `run()` reads nothing from the environment; every parameter is a constant. Under
`forge script --broadcast`, salted creates go through the deterministic CREATE2 deployer proxy
(`0x4e59b44847b379578588920cA78FbF26c0B4956C`), which is why the script mines against that address.
This repository does not authorize any transaction and controls no wallet; deployment is the
services' step after review.

## Operational responsibilities

- **Burning.** `burnFees(currency)` is permissionless and nobody is obliged to call it. Claims sit
  safely on the hook until someone does; the accounting invariant (claims equal unburned fees) holds
  either way. The site or any keeper may call it for both `WHAL` and ETH (`address(0)`).
- **Routing and slippage.** Routers and quoters must account for the hook delta: exact-in swappers
  receive `output - fee`, exact-out swappers pay `input + fee`. Minimum-output and maximum-input
  parameters have to include the tax. The fee preview should be an `eth_call` simulation of the swap
  (which runs the real hook), not a formula computed off-chain from the curve alone.
- **Monitoring.** Watch `WhaleTax` events for the effective rate and `FeesBurned` for burns.
  `accruedFees`, `totalFeesCollected` and `totalFeesBurned` give the running totals. The pool price
  comes from Uniswap's Sepolia `StateView` or `PoolManager.extsload` via `StateLibrary`.
- **Nothing to rotate, pause or upgrade.** There is no key. Incident response is "stop routing to
  the pool", not "call the admin".
- **Independent review.** Tests passing is not an audit. The workflow requires a separate read-only
  adversarial review before launch; the surfaces it should attack are listed below.

## Surfaces for the adversarial review

| Surface                                       | Where                                              | Tests already covering it |
| --------------------------------------------- | -------------------------------------------------- | ------------------------- |
| Impact maths: overflow, rounding, direction   | `priceMoveBps`, `feeBpsForMove`                    | `test_priceMoveBps*`, `testFuzz_priceMoveBps*`, `test_feeCurve`, `test_twoAndAHalfPercent*`, `test_fivePercent*` |
| Transient slot across swaps in one tx         | `_tstorePreSwapPrice` / `_tloadPreSwapPrice`       | `test_twoSwapsInOneTransaction*`, `test_threeSwaps*` |
| Fee never exceeding the unspecified leg       | `afterSwap`, `feeAmount`                           | `testFuzz_feeNeverExceeds*`, `testFuzz_swapSizesAndShapes`, `assertTaxEventConsistent` |
| Zero liquidity, price jumps to the limit      | `afterSwap` via `priceMoveBps` saturation          | `test_zeroLiquidityJump*`, `test_sellIntoEthLessPoolIsHarmless`, `test_swapThatRunsPastTheLiquidity*` |
| `burnFees` accounting                         | `burnFees`, `unlockCallback`                       | `test_burnFees*`, `testFuzz_claimsAlwaysEqualUnburnedFees`, `test_strangerCannotDriveTheUnlockCallback` |
| Caller checks                                 | `onlyPoolManager` on every callback                | `test_swapCallbacksRefuse*`, `test_undeclaredCallbacksRevert` |

## Tests

`forge test` runs 55 tests in three suites. They deploy a real v4-core `PoolManager`, mine the hook's
CREATE2 salt, and drive swaps through v4-core's `PoolSwapTest` / `PoolModifyLiquidityTest` routers
plus a small batch router (`test/utils/BatchSwapRouter.sol`) for several swaps in one transaction.
They read no environment variables and do not depend on the calling address, so they pass in any
order and in parallel.

- `test/WhaleToken.t.sol`: supply, metadata, transfers, no admin surface, no forbidden opcodes.
- `test/WhaleTaxHook.t.sol`: permissions and mined-address construction, the fee curve and price-move
  maths (including the exact 30 / 265 / 500 bps cases), caller checks, exact-in and exact-out in both
  directions, dust, engineered 2.5% and 5%+ moves both ways, two and three swaps in one transaction,
  a non-ETH pool, zero-liquidity jumps, `burnFees` success and failure, and fuzzed sequences of swaps
  and burns asserting that the hook's claims always equal its unburned fees.
- `test/LaunchRehearsal.t.sol`: the factory's sequence (initialize at the rehearsal price, one-sided
  WHAL seed, first buy into an ETH-less pool, then sells, exact-out buys and burns), plus the deploy
  script's `deploy` function against a local PoolManager.

`test/mocks/MockERC20.sol` and `src/HookFlags.sol` are also what the launch floor tests import.
