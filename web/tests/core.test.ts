import { test } from "node:test";
import assert from "node:assert/strict";
import {
  amountOf,
  priceLimit,
  splitDelta,
  feeForMove,
  sqrt,
  MIN_SQRT,
  MAX_SQRT,
} from "../src/math.ts";
import { switchChain, Chain } from "../src/chain.ts";
import type { Config } from "../src/config.ts";
import { safePath } from "../src/config.ts";
import { readFileSync } from "node:fs";
const d = JSON.parse(readFileSync("../dist/imd-deployment.json", "utf8"));
const c = { deployment: d } as Config;
test("amount parsing rejects ambiguous, overprecise, zero and negative input", () => {
  for (const a of ["0", "-1", "NaN", "1e3", "0x10", ".1", "1.1234567"])
    assert.throws(() => amountOf(a, 6));
  assert.equal(amountOf("12.000001", 6), 12000001n);
});
test("fee curve includes all approval boundaries and caps", () => {
  assert.equal(feeForMove(0), 30);
  assert.equal(feeForMove(250), 265);
  assert.equal(feeForMove(500), 500);
  assert.equal(feeForMove(99999), 500);
  assert.equal(feeForMove(1), 30);
});
test("price limits use integer math, move in the correct direction and clamp", () => {
  const p = 2n ** 96n;
  assert.ok(priceLimit(p, "0.5", true) < p);
  assert.ok(priceLimit(p, "0.5", false) > p);
  assert.equal(priceLimit(MIN_SQRT, "5", true), MIN_SQRT);
  assert.equal(priceLimit(MAX_SQRT, "5", false), MAX_SQRT);
  assert.throws(() => priceLimit(p, "5.01", true));
  assert.throws(() => priceLimit(p, "0", true));
  assert.equal(sqrt(999999n), 999n);
});
test("packed delta sign extension works for buy and sell", () => {
  const pack = (a: bigint, b: bigint) => (a << 128n) | BigInt.asUintN(128, b);
  assert.deepEqual(splitDelta(pack(-10n, 200n)), [-10n, 200n]);
  assert.deepEqual(splitDelta(pack(100n, -3000n)), [100n, -3000n]);
});
test("manifest asset paths cannot escape export or refer to a URL", () => {
  for (const p of ["../x", "/x", "https://host/a", "a/../b"])
    assert.throws(() => safePath(p));
  assert.equal(safePath("abi/A.json"), "abi/A.json");
});
test("unknown chain triggers exact add-chain handoff then retries switch", async () => {
  const requests: any[] = [];
  let first = true;
  await switchChain(
    {
      request: async (args) => {
        requests.push(args);
        if (first) {
          first = false;
          throw { code: 4902 };
        }
      },
    },
    c,
  );
  assert.deepEqual(
    requests.map((v) => v.method),
    [
      "wallet_switchEthereumChain",
      "wallet_addEthereumChain",
      "wallet_switchEthereumChain",
    ],
  );
  assert.deepEqual(requests[1].params, [d.walletAddChain]);
});
test("wallet rejection does not attempt add chain", async () => {
  const calls: string[] = [];
  await assert.rejects(
    switchChain(
      {
        request: async (a) => {
          calls.push(a.method);
          throw { code: 4001 };
        },
      },
      c,
    ),
  );
  assert.deepEqual(calls, ["wallet_switchEthereumChain"]);
});
test("account changes and expired previews block before a wallet send", async () => {
  const e = new Chain(c);
  e.wallet = {
    request: async (a) =>
      a.method === "eth_chainId"
        ? d.walletAddChain.chainId
        : ["0x0000000000000000000000000000000000000001"],
  };
  await assert.rejects(
    e.assertWallet("0x0000000000000000000000000000000000000002"),
    /account changed/,
  );
  await assert.rejects(
    e.swap("0x0000000000000000000000000000000000000001", { time: 0 } as any),
    /expired/,
  );
});

test("wallet read fallback is used only on the attested chain", async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => {
    throw Error("Public RPC unavailable");
  };
  try {
    const e = new Chain(c),
      calls: string[] = [];
    e.wallet = {
      request: async ({ method }) => {
        calls.push(method);
        return method === "eth_chainId" ? d.walletAddChain.chainId : "0x123";
      },
    };
    assert.equal(await e.rpc("eth_blockNumber"), "0x123");
    assert.equal(await e.rpc("eth_chainId"), d.walletAddChain.chainId);
    assert.deepEqual(calls, ["eth_chainId", "eth_blockNumber", "eth_chainId"]);
    e.wallet = { request: async () => "0x1" };
    await assert.rejects(e.rpc("eth_blockNumber"), /Public RPC unavailable/);
  } finally {
    globalThis.fetch = originalFetch;
  }
});
