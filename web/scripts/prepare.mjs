import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import solc from "solc";
import { parseAbi } from "viem";
import { handoff, abiHash } from "./shared.mjs";
mkdirSync("public/abi", { recursive: true });
for (const c of handoff.contracts) {
  const bytes = execFileSync("git", [
    "show",
    `${handoff.sourceCommit}:docs/abi/${c.name}.json`,
  ]);
  const abi = JSON.parse(bytes);
  if (!Array.isArray(abi) || abiHash(abi) !== c.abiHash)
    throw Error(`Pinned ABI hash mismatch: ${c.name} (${abiHash(abi)})`);
  if (!bytes.equals(readFileSync(`../docs/abi/${c.name}.json`)))
    throw Error(`Working ABI differs from pinned source: ${c.name}`);
  writeFileSync(`public/abi/${c.name}.json`, bytes);
  console.log(`Verified ${c.name}: ${c.abiHash}`);
}
const common = [
  "struct PoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }",
  "struct SwapParams { bool zeroForOne; int256 amountSpecified; uint160 sqrtPriceLimitX96; }",
  "struct TestSettings { bool takeClaims; bool settleUsingBurn; }",
  "struct QuoteParams { PoolKey poolKey; bool zeroForOne; uint128 exactAmount; bytes hookData; }",
  "function swap(PoolKey key, SwapParams params, TestSettings testSettings, bytes hookData) payable returns (int256 delta)",
  "function manager() view returns (address)",
  "function getSlot0(bytes32 poolId) view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)",
  "function getLiquidity(bytes32 poolId) view returns (uint128 liquidity)",
  "function quoteExactInputSingle(QuoteParams params) returns (uint256 amountOut, uint256 gasEstimate)",
];
writeFileSync(
  "public/abi/Uniswap.json",
  JSON.stringify(parseAbi(common), null, 2) + "\n",
);
const output = JSON.parse(
  solc.compile(
    JSON.stringify({
      language: "Solidity",
      sources: {
        "PreviewLens.sol": {
          content: readFileSync("simulation/PreviewLens.sol", "utf8"),
        },
      },
      settings: {
        optimizer: { enabled: true, runs: 200 },
        viaIR: true,
        evmVersion: "cancun",
        metadata: { bytecodeHash: "none" },
        outputSelection: {
          "*": { "*": ["abi", "evm.deployedBytecode.object"] },
        },
      },
    }),
  ),
);
if (output.errors?.some((e) => e.severity === "error"))
  throw Error(JSON.stringify(output.errors));
const lens = output.contracts["PreviewLens.sol"].PreviewLens;
mkdirSync("public/simulation", { recursive: true });
writeFileSync(
  "public/simulation/PreviewLens.json",
  JSON.stringify(
    { abi: lens.abi, bytecode: `0x${lens.evm.deployedBytecode.object}` },
    null,
    2,
  ) + "\n",
);
