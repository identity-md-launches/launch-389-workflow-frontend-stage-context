import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { handoff, network, integrations } from "./shared.mjs";
const files = readdirSync("../dist", { recursive: true, withFileTypes: true })
  .filter((f) => f.isFile())
  .map((f) => `${f.parentPath}/${f.name}`.replace("../dist/", ""))
  .filter((f) => f !== "imd-deployment.json")
  .sort();
if (files.length > 128) throw Error("Asset count exceeds 128");
const assets = files.map((path) => {
  const bytes = readFileSync(`../dist/${path}`);
  if (bytes.length > 8388608) throw Error("Asset too large");
  return { path, sha256: createHash("sha256").update(bytes).digest("hex") };
});
const manifest = {
  version: 1,
  launchId: handoff.launchId,
  chainId: handoff.chainId,
  sourceCommit: handoff.sourceCommit,
  attestationHash: handoff.attestationHash,
  contracts: handoff.contracts.map(({ name, address, abiHash }) => ({
    name,
    address,
    abiHash,
    abiPath: `abi/${name}.json`,
  })),
  assets,
  network: network.network,
  walletAddChain: network.walletAddChain,
  pool: handoff.manifest.pool,
  deploymentBlock: Math.min(...handoff.contracts.map((c) => c.blockNumber)),
  integrations,
};
writeFileSync(
  "../dist/imd-deployment.json",
  JSON.stringify(manifest, null, 2) + "\n",
);
console.log(`Manifest emitted last: ${assets.length} assets`);
