# Vendored dependencies

Everything under `lib/` is committed as ordinary files (no git submodules), because the
verifier builds this repository with no network access. Each entry records the upstream
commit the files were copied from so a reviewer can diff against it.

| Directory                   | Upstream                                              | Commit                                     | Files kept                                                                                                  |
| --------------------------- | ----------------------------------------------------- | ------------------------------------------ | ----------------------------------------------------------------------------------------------------------- |
| `lib/forge-std`             | https://github.com/foundry-rs/forge-std               | `3e2295d50379faa6c8e9859d51b1f97a69a830d1` | `src/`, licenses                                                                                            |
| `lib/v4-core`               | https://github.com/Uniswap/v4-core                    | `46c6834698c48bc4a463a86d8420f4eb1d7f3b75` | `src/` (core + `src/test` routers), `test/utils/` (CurrencySettler, LiquidityAmounts, Constants), licenses |
| `lib/solmate`               | https://github.com/transmissions11/solmate            | `89365b880c4f3c786bdd453d4b8e8fe410344a69` | `src/auth/Owned.sol`, `src/tokens/ERC20.sol`, `src/utils/FixedPointMathLib.sol`, `src/test/utils/mocks/MockERC20.sol`, license |
| `lib/openzeppelin-contracts`| https://github.com/OpenZeppelin/openzeppelin-contracts | `4858ab13a5ad897f59753028f6315f9d487c4322` | `contracts/token/ERC20/{ERC20,IERC20}.sol`, `extensions/IERC20Metadata.sol`, `interfaces/IERC6093.sol`, `utils/Context.sol`, `proxy/Proxy.sol`, license |

Only the files that the project (and the v4-core sources it imports) actually reference were
copied. v4-core's `src/test/ProxyPoolManager.sol` needs OpenZeppelin's `Proxy.sol`; it is kept so
the whole vendored `src/` tree compiles, but nothing in this project deploys it.

The remappings in `remappings.txt` mirror v4-core's own (`v4-core/`, `solmate/`,
`@openzeppelin/contracts/`, `forge-std/`).
