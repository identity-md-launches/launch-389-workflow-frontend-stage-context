import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { handoff, network, abiHash } from "./shared.mjs";
const d = JSON.parse(readFileSync("../dist/imd-deployment.json"));
for (const key of [
  "version",
  "launchId",
  "chainId",
  "sourceCommit",
  "attestationHash",
])
  assert.equal(d[key], handoff[key]);
assert.deepEqual(d.network, network.network);
assert.deepEqual(d.walletAddChain, network.walletAddChain);
assert.deepEqual(
  d.contracts.map(({ name, address, abiHash }) => ({ name, address, abiHash })),
  handoff.contracts.map(({ name, address, abiHash }) => ({
    name,
    address,
    abiHash,
  })),
);
let bytes = 0;
for (const a of d.assets) {
  assert.match(a.path, /^(?!\/)(?!.*\.\.)[a-zA-Z0-9_./-]+$/);
  const file = readFileSync(`../dist/${a.path}`);
  bytes += file.length;
  assert.ok(file.length <= 8388608);
  assert.equal(createHash("sha256").update(file).digest("hex"), a.sha256);
}
for (const c of d.contracts)
  assert.equal(
    abiHash(JSON.parse(readFileSync(`../dist/${c.abiPath}`))),
    c.abiHash,
  );
const actual = readdirSync("../dist", { recursive: true, withFileTypes: true })
  .filter((f) => f.isFile())
  .map((f) => `${f.parentPath}/${f.name}`.replace("../dist/", ""))
  .filter((f) => f !== "imd-deployment.json")
  .sort();
assert.deepEqual(d.assets.map((a) => a.path).sort(), actual);
assert.ok(d.assets.length <= 128 && bytes < 32 * 1024 * 1024);
console.log(
  `PASS: ${d.assets.length} assets, ${bytes} bytes; hashes, complete inventory, handoff, network and ABI binding verified.`,
);
