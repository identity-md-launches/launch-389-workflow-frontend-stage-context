import { readFileSync, writeFileSync } from "node:fs";
import { Chain } from "../src/chain.ts";
import type { Config } from "../src/config.ts";
const read = (p: string) => JSON.parse(readFileSync(`../dist/${p}`, "utf8"));
const d = read("imd-deployment.json");
const contract = (name: string) => {
  const c = d.contracts.find((v: any) => v.name === name);
  return { address: c.address, abi: read(c.abiPath) };
};
const config: Config = {
  deployment: d,
  token: contract("WhaleToken"),
  hook: contract("WhaleTaxHook"),
  uniswap: read(d.integrations.abiPath),
  lens: read(d.integrations.previewLensArtifact),
};
const engine = new Chain(config);
const evidence: any = {
  date: new Date().toISOString(),
  transactionsBroadcast: 0,
};
try {
  evidence.code = await engine.verify();
  evidence.state = await engine.snapshot();
  evidence.events = await engine.events(evidence.state.block);
  for (const [buy, amount] of [
    [true, 1000000000000000n],
    [false, 100000000000000000000n],
  ] as const) {
    try {
      evidence[buy ? "buyQuote" : "sellQuote"] = await engine.quote(
        amount,
        buy,
        "0.5",
      );
    } catch (e) {
      evidence[buy ? "buyQuoteError" : "sellQuoteError"] =
        e instanceof Error ? e.message : String(e);
    }
  }
  evidence.rpc = engine.lastRpc;
} catch (e) {
  evidence.error = e instanceof Error ? e.message : String(e);
  process.exitCode = 1;
}
writeFileSync(
  "../docs/evidence/live-chain.json",
  JSON.stringify(
    evidence,
    (_, v) => (typeof v === "bigint" ? v.toString() : v),
    2,
  ) + "\n",
);
console.log(
  JSON.stringify(
    evidence,
    (_, v) => (typeof v === "bigint" ? v.toString() : v),
    2,
  ),
);
