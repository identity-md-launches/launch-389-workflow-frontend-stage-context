import { chromium, expect } from "@playwright/test";
import AxeBuilder from "@axe-core/playwright";
import { readFileSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
import { resolve, extname } from "node:path";
import {
  decodeFunctionData,
  encodeFunctionResult,
  encodeEventTopics,
  encodeAbiParameters,
  parseAbi,
  toHex,
} from "viem";
mkdirSync("../docs/evidence", { recursive: true });
const dist = resolve("../dist");
const manifest = JSON.parse(readFileSync(`${dist}/imd-deployment.json`));
const abi = (name) => JSON.parse(readFileSync(`${dist}/abi/${name}.json`));
const token = manifest.contracts.find((c) => c.name === "WhaleToken");
const hook = manifest.contracts.find((c) => c.name === "WhaleTaxHook");
const uni = abi("Uniswap"),
  tokenAbi = abi("WhaleToken"),
  hookAbi = abi("WhaleTaxHook");
const lens = JSON.parse(
  readFileSync(`${dist}/${manifest.integrations.previewLensArtifact}`),
);
const account = "0x1111111111111111111111111111111111111111";
const zero = "0x0000000000000000000000000000000000000000";
const hash = "0x" + "ab".repeat(32);
const block = 12000000n,
  before = 560227709747861399187319382274582n;
let swapCount = 0;
const json = (v) =>
  JSON.stringify(v, (_, v) => (typeof v === "bigint" ? v.toString() : v));
const url = "https://whale.test/preview/";
const browser = await chromium.launch({
  headless: true,
  executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE,
  args: ["--no-sandbox"],
});
const report = {
  date: new Date().toISOString(),
  url,
  checks: [],
  consoleErrors: [],
  resourceFailures: [],
  screenshots: [],
  axe: [],
  contrast: [],
};
let page;
const check = (name) => {
  report.checks.push(name);
  console.log(`PASS ${name}`);
};
async function fixture({
  wallet = true,
  chain = "0x1",
  reject = false,
  missingCode = false,
  readFail = false,
  swapFail = false,
  tamperAbi = false,
  quoteFail = false,
  events = true,
} = {}) {
  const context = await browser.newContext({
    viewport: { width: 1440, height: 1100 },
  });
  if (wallet)
    await context.addInitScript(
      ({ account, chain, reject }) => {
        window.mock = {
          chain,
          account,
          connected: false,
          added: false,
          reject,
          txs: [],
          requests: [],
          listeners: {},
          allowance: "0",
          burned: false,
        };
        window.ethereum = {
          on: (e, fn) => (window.mock.listeners[e] ??= []).push(fn),
          removeListener: (e, fn) => {
            window.mock.listeners[e] = window.mock.listeners[e]?.filter(
              (v) => v !== fn,
            );
          },
          request: async ({ method, params = [] }) => {
            const m = window.mock;
            m.requests.push({ method, params });
            if (method === "eth_accounts")
              return m.connected ? [m.account] : [];
            if (method === "eth_requestAccounts") {
              if (m.reject) throw { code: 4001, message: "User rejected" };
              m.connected = true;
              return [m.account];
            }
            if (method === "eth_chainId") return m.chain;
            if (method === "wallet_switchEthereumChain") {
              if (!m.added) throw { code: 4902, message: "Unknown chain" };
              m.chain = params[0].chainId;
              for (const fn of m.listeners.chainChanged ?? []) fn(m.chain);
              return null;
            }
            if (method === "wallet_addEthereumChain") {
              m.added = true;
              return null;
            }
            if (method === "eth_sendTransaction") {
              if (m.reject) throw { code: 4001, message: "User rejected" };
              m.txs.push(params[0]);
              return "0x" + "ab".repeat(32);
            }
            throw Error(`Unexpected wallet request: ${method}`);
          },
        };
      },
      { account, chain, reject },
    );
  await context.route("https://whale.test/**", async (route) => {
    const path = new URL(route.request().url()).pathname;
    const file = resolve(
      dist,
      path === "/preview/" ? "index.html" : path.replace(/^\/preview\//, ""),
    );
    if (!file.startsWith(dist + "/"))
      return route.fulfill({ status: 404, body: "Not found" });
    try {
      await route.fulfill({
        status: 200,
        body:
          tamperAbi && file.endsWith("WhaleToken.json")
            ? Buffer.from("[]")
            : readFileSync(file),
        contentType:
          {
            ".html": "text/html",
            ".js": "text/javascript",
            ".css": "text/css",
            ".json": "application/json",
          }[extname(file)] ?? "application/octet-stream",
      });
    } catch {
      await route.fulfill({ status: 404, body: "Not found" });
    }
  });
  const p = await context.newPage();
  p.on("pageerror", (e) => report.consoleErrors.push(e.message));
  p.on("requestfailed", (r) => {
    if (!r.url().includes("rpc"))
      report.resourceFailures.push(r.url() + ": " + r.failure()?.errorText);
  });
  await p.route(
    /https:\/\/(ethereum-sepolia-rpc\.publicnode\.com|rpc\.sepolia\.ethpandaops\.io|sepolia\.rpc\.sentio\.xyz)/,
    async (route) => {
      const body = route.request().postDataJSON();
      let result;
      const fail = (message) =>
        route.fulfill({
          json: {
            jsonrpc: "2.0",
            id: body.id,
            error: { code: -32000, message },
          },
        });
      if (readFail) return fail("RPC unavailable in test");
      const { method, params } = body;
      try {
        if (method === "eth_chainId") result = manifest.walletAddChain.chainId;
        else if (method === "eth_blockNumber") result = toHex(block);
        else if (method === "eth_getCode")
          result =
            params[0].toLowerCase() ===
            manifest.integrations.previewLens.toLowerCase()
              ? "0x"
              : missingCode &&
                  params[0].toLowerCase() === manifest.integrations.poolSwapTest
                ? "0x"
                : "0x60016000";
        else if (method === "eth_getBalance") result = toHex(10n ** 20n);
        else if (method === "eth_estimateGas") result = "0x70000";
        else if (method === "eth_getTransactionReceipt") {
          const txs = await p.evaluate(() => window.mock?.txs ?? []);
          const last = txs.at(-1);
          if (last?.to.toLowerCase() === token.address) {
            const decoded = decodeFunctionData({
              abi: tokenAbi,
              data: last.data,
            });
            if (decoded.functionName === "approve")
              await p.evaluate(
                (v) => (window.mock.allowance = v),
                decoded.args[1].toString(),
              );
          }
          if (last?.to.toLowerCase() === hook.address)
            await p.evaluate(() => (window.mock.burned = true));
          result = {
            status: "0x1",
            transactionHash: hash,
            blockNumber: toHex(block),
          };
        } else if (method === "eth_getLogs") {
          const poolId = encodeEventTopics({
            abi: hookAbi,
            eventName: "WhaleTax",
            args: { poolId: "0x" + "00".repeat(32), currency: token.address },
          });
          // The app must ignore unrelated pools, then display a currency-specific burn.
          result = events
            ? [
                {
                  topics: poolId,
                  data: encodeAbiParameters(
                    [
                      { type: "uint256" },
                      { type: "uint256" },
                      { type: "uint256" },
                    ],
                    [250n, 265n, 1000n],
                  ),
                  blockNumber: toHex(block),
                  transactionHash: hash,
                  logIndex: "0x0",
                },
                {
                  topics: encodeEventTopics({
                    abi: hookAbi,
                    eventName: "FeesBurned",
                    args: { currency: token.address },
                  }),
                  data: encodeAbiParameters(
                    [{ type: "uint256" }],
                    [10n ** 18n],
                  ),
                  blockNumber: toHex(block),
                  transactionHash: hash,
                  logIndex: "0x1",
                },
              ]
            : [];
        } else if (method === "eth_call") {
          const tx = params[0],
            addr = tx.to.toLowerCase();
          let a =
            addr === token.address
              ? tokenAbi
              : addr === hook.address
                ? hookAbi
                : addr === manifest.integrations.previewLens
                  ? lens.abi
                  : uni;
          const { functionName: name, args = [] } = decodeFunctionData({
            abi: a,
            data: tx.data,
          });
          let value;
          if (name === "poolManager" || name === "manager")
            value = manifest.network.uniswapV4.poolManager;
          else if (name === "getSlot0") value = [before, 177284, 0, 3000];
          else if (name === "getLiquidity") value = 1000000000000n;
          else if (name === "decimals") value = 18;
          else if (name === "symbol") value = "WHAL";
          else if (name === "totalSupply") value = 10n ** 27n;
          else if (name === "balanceOf") value = 10n ** 24n;
          else if (name === "allowance")
            value = BigInt(
              await p.evaluate(() => window.mock?.allowance ?? "0"),
            );
          else if (name === "feeBpsForMove")
            value = 30n + (470n * (args[0] > 500n ? 500n : args[0])) / 500n;
          else if (
            [
              "accruedFees",
              "claimsOf",
              "totalFeesCollected",
              "totalFeesBurned",
            ].includes(name)
          ) {
            const burned = await p.evaluate(() => window.mock?.burned ?? false);
            value =
              name === "totalFeesBurned"
                ? burned
                  ? 10n ** 18n
                  : 0n
                : name === "totalFeesCollected"
                  ? 10n ** 18n
                  : burned
                    ? 0n
                    : 10n ** 18n;
          } else if (name === "quote") {
            if (quoteFail) return fail("Simulation reverted: no liquidity");
            const buy = args[3].zeroForOne,
              amount = -args[3].amountSpecified,
              output = buy ? amount * 49000000n : amount / 49000000n;
            const pack = (a, b) => (a << 128n) | BigInt.asUintN(128, b);
            value = [
              buy ? pack(-amount, output) : pack(output, -amount),
              before,
              buy ? (before * 997n) / 1000n : (before * 1003n) / 1000n,
              59n,
              85n,
              (output * 85n) / 9915n,
            ];
          } else if (name === "quoteExactInputSingle")
            value = [
              args[0].zeroForOne
                ? args[0].exactAmount * 49000000n
                : args[0].exactAmount / 49000000n,
              100000n,
            ];
          else if (name === "approve" || name === "transfer") value = true;
          else if (name === "burnFees") value = 10n ** 18n;
          else if (name === "swap") {
            if (swapFail) return fail("PoolSwapTest simulation reverted");
            swapCount++;
            value = 0n;
          } else throw Error(`Unmocked call ${name}`);
          result = encodeFunctionResult({
            abi: a,
            functionName: name,
            result: value,
          });
        } else throw Error(`Unmocked RPC ${method}`);
        await route.fulfill({ json: { jsonrpc: "2.0", id: body.id, result } });
      } catch (e) {
        console.error(e);
        await fail(e.message);
      }
    },
  );
  await p.clock.install();
  await p.goto(url);
  if (readFail || missingCode || tamperAbi)
    await expect(p.getByRole("alert")).toBeVisible({ timeout: 20000 });
  else
    await expect(p.getByText("Live · block")).toBeVisible({ timeout: 20000 });
  return p;
}
try {
  page = await fixture();
  await expect(
    page.getByRole("button", { name: "Preview swap", exact: true }),
  ).toBeEnabled();
  await expect(
    page.getByText("Fee claims burned", { exact: true }),
  ).toBeVisible();
  check(
    "Manifest and ABI assets load from /preview/; disconnected live reads and event filtering",
  );
  await page.getByRole("button", { name: "Preview swap", exact: true }).click();
  await expect(page.getByText("0.59%", { exact: true })).toBeVisible();
  check(
    "Typed buy preview displays simulated move, fee, output and price limit",
  );
  await page
    .getByRole("button", { name: "Connect wallet", exact: true })
    .click();
  await expect(
    page.getByRole("button", { name: "Switch to Sepolia" }),
  ).toBeVisible();
  await page.getByRole("button", { name: "Switch to Sepolia" }).click();
  await expect(
    page.getByText("Network switched. Preview your swap."),
  ).toBeVisible();
  const add = await page.evaluate(
    () =>
      window.mock.requests.find((r) => r.method === "wallet_addEthereumChain")
        .params[0],
  );
  expect(add).toEqual(manifest.walletAddChain);
  check(
    "Unknown wallet chain: switch rejection, exact add-chain payload, second switch",
  );
  await page.getByRole("button", { name: "Preview swap", exact: true }).click();
  await page.getByRole("button", { name: "Confirm buy in wallet" }).click();
  await expect(
    page.getByText("Buy WHAL confirmed.", { exact: false }),
  ).toBeVisible();
  let txs = await page.evaluate(() => window.mock.txs);
  expect(txs[0].to).toBe(manifest.integrations.poolSwapTest);
  expect(BigInt(txs[0].value)).toBe(1000000000000000n);
  expect(decodeFunctionData({ abi: uni, data: txs[0].data }).args[2]).toEqual({
    takeClaims: false,
    settleUsingBurn: false,
  });
  check(
    "Buy simulates actual PoolSwapTest call, requests correct native value, waits for receipt",
  );
  await page.getByRole("button", { name: "Sell WHAL", exact: true }).click();
  await page.getByRole("button", { name: "Preview swap", exact: true }).click();
  await page
    .getByRole("button", { name: "Approve 100 WHAL", exact: true })
    .click();
  await expect(
    page.getByText("WHAL approval confirmed.", { exact: false }),
  ).toBeVisible();
  txs = await page.evaluate(() => window.mock.txs);
  const approval = decodeFunctionData({ abi: tokenAbi, data: txs.at(-1).data });
  expect(approval.functionName).toBe("approve");
  expect(approval.args[0].toLowerCase()).toBe(
    manifest.integrations.poolSwapTest,
  );
  expect(approval.args[1]).toBe(100n * 10n ** 18n);
  await page.getByRole("button", { name: "Preview swap", exact: true }).click();
  await page.getByRole("button", { name: "Confirm sell in wallet" }).click();
  await expect(
    page.getByText("Sell WHAL confirmed.", { exact: false }),
  ).toBeVisible();
  txs = await page.evaluate(() => window.mock.txs);
  expect(BigInt(txs.at(-1).value)).toBe(0n);
  check(
    "Sell requires exact-amount router approval; quote invalidates after receipt; sell uses zero native value",
  );
  await page
    .getByText("Send accrued claims to the dead address", { exact: true })
    .click();
  await expect(
    page.getByRole("button", { name: "Burn ETH fee claims", exact: true }),
  ).toBeDisabled();
  await page.getByLabel("I understand the claims").check();
  await page
    .getByRole("button", { name: "Burn ETH fee claims", exact: true })
    .click();
  await expect(
    page.getByText("Fee claim burn confirmed.", { exact: false }),
  ).toBeVisible();
  check(
    "Permissionless burn requires explicit consequence acknowledgment, simulates and confirms",
  );
  await page.getByText("Pool details & wallet tools", { exact: true }).click();
  await page
    .getByLabel("Recipient address")
    .fill("0x2222222222222222222222222222222222222222");
  await page.getByLabel("WHAL to transfer").fill("3");
  await page
    .getByRole("button", { name: "Transfer WHAL", exact: true })
    .click();
  await expect(
    page.getByText("WHAL transfer confirmed.", { exact: false }),
  ).toBeVisible();
  await page.getByRole("button", { name: "Revoke router allowance" }).click();
  await expect(
    page.getByText("Allowance removal confirmed.", { exact: false }),
  ).toBeVisible();
  check(
    "WHAL transfer and allowance revocation controls complete mocked receipts",
  );
  await page.getByRole("button", { name: "Buy WHAL", exact: true }).click();
  await page.getByLabel("You pay", { exact: false }).fill("0");
  await page.getByRole("button", { name: "Preview swap", exact: true }).click();
  await expect(page.getByRole("alert")).toContainText("positive amount");
  await expect(page.locator("#amount")).toBeFocused();
  check("Invalid amount is explained and focused");
  await page.locator("#amount").fill("0.001");
  await page.getByRole("button", { name: "Preview swap", exact: true }).click();
  await page.evaluate(() => {
    window.mock.account = "0x3333333333333333333333333333333333333333";
    for (const f of window.mock.listeners.accountsChanged ?? [])
      f([window.mock.account]);
  });
  await expect(
    page.getByRole("button", { name: "Confirm buy in wallet" }),
  ).toHaveCount(0);
  check("Account change invalidates a ready quote");
  await page.getByRole("button", { name: "Preview swap", exact: true }).click();
  await expect(
    page.getByRole("button", { name: "Confirm buy in wallet" }),
  ).toBeVisible();
  await page.clock.fastForward(61000);
  await expect(
    page.getByText("Preview expired. Simulate again."),
  ).toBeVisible();
  await expect(
    page.getByRole("button", { name: "Confirm buy in wallet" }),
  ).toHaveCount(0);
  check("Quote expires after 60 seconds");
  await page.context().close();
  page = await fixture();
  await page.getByRole("button", { name: "Preview swap", exact: true }).click();
  await expect(page.getByText("0.59%", { exact: true })).toBeVisible();
  await page.keyboard.press("Tab");
  await page.keyboard.press("Tab");
  for (const width of [1440, 820, 390, 320]) {
    await page.setViewportSize({ width, height: width === 1440 ? 1100 : 1000 });
    expect(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= innerWidth,
      ),
    ).toBe(true);
    const file = `../docs/evidence/desktop-${width}.png`;
    await page.screenshot({ path: file, fullPage: true });
    report.screenshots.push(file.replace("../", ""));
    const scan = await new AxeBuilder({ page })
      .withTags(["wcag2a", "wcag2aa", "wcag21aa"])
      .analyze();
    report.axe.push({
      width,
      violations: scan.violations.map((v) => ({
        id: v.id,
        impact: v.impact,
        nodes: v.nodes.map((n) => n.target),
      })),
    });
    expect(scan.violations).toEqual([]);
  }
  check(
    "Production export at 1440/820/390/320px: no horizontal overflow; axe WCAG 2 A/AA and 2.1 AA checks",
  );
  await page.setViewportSize({ width: 1440, height: 1100 });
  await page.evaluate(() => (document.documentElement.style.fontSize = "32px"));
  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= innerWidth,
    ),
  ).toBe(true);
  await page.screenshot({
    path: "../docs/evidence/text-200.png",
    fullPage: true,
  });
  report.screenshots.push("docs/evidence/text-200.png");
  await page.evaluate(() => (document.documentElement.style.fontSize = ""));
  check("200% text enlargement reflow (not native browser zoom)");
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.keyboard.press("Control+Home");
  await page.keyboard.press("Tab");
  await page.screenshot({
    path: "../docs/evidence/focus.png",
    fullPage: false,
  });
  report.screenshots.push("docs/evidence/focus.png");
  report.contrast = await page.evaluate(() => {
    const rgb = (s) => s.match(/\d+/g).slice(0, 3).map(Number);
    const luminance = (c) =>
      c
        .map((v) => {
          v /= 255;
          return v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
        })
        .reduce((a, v, i) => a + v * [0.2126, 0.7152, 0.0722][i], 0);
    return [".primary", ".lead", ".warning-text", ".network-pill"].map(
      (selector) => {
        const el = document.querySelector(selector),
          style = getComputedStyle(el);
        let node = el,
          bg;
        while (node) {
          bg = getComputedStyle(node).backgroundColor;
          if (bg !== "rgba(0, 0, 0, 0)") break;
          node = node.parentElement;
        }
        const a = luminance(rgb(style.color)),
          b = luminance(rgb(bg));
        return {
          selector,
          foreground: style.color,
          background: bg,
          ratio: (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05),
        };
      },
    );
  });
  await page.context().close();
  for (const scenario of [
    { wallet: false },
    { reject: true },
    { missingCode: true },
    { quoteFail: true },
    { readFail: true },
    { tamperAbi: true },
    { swapFail: true, chain: manifest.walletAddChain.chainId },
  ]) {
    page = await fixture(scenario);
    if (scenario.wallet === false || scenario.reject) {
      await page
        .getByRole("button", { name: "Connect wallet", exact: true })
        .click();
      await expect(page.getByRole("alert")).toContainText(
        scenario.reject ? "declined" : "No browser wallet",
      );
    }
    if (scenario.tamperAbi) {
      await expect(page.getByRole("alert")).toContainText(
        "Asset integrity check failed",
      );
      await expect(
        page.getByRole("button", { name: "Preview swap", exact: true }),
      ).toBeDisabled();
    }
    if (scenario.swapFail) {
      await page
        .getByRole("button", { name: "Connect wallet", exact: true })
        .click();
      await page
        .getByRole("button", { name: "Preview swap", exact: true })
        .click();
      await page.getByRole("button", { name: "Confirm buy in wallet" }).click();
      await expect(page.getByRole("alert")).toContainText(
        "simulation reverted",
      );
      expect(await page.evaluate(() => window.mock.txs.length)).toBe(0);
    }
    if (scenario.missingCode) {
      await expect(
        page.getByText(/A required contract has no code/),
      ).toBeVisible();
      await expect(
        page.getByRole("button", { name: "Preview swap", exact: true }),
      ).toBeDisabled();
    }
    if (scenario.quoteFail) {
      await page
        .getByRole("button", { name: "Preview swap", exact: true })
        .click();
      await expect(page.getByRole("alert")).toContainText("Fee preview failed");
    }
    if (scenario.readFail) {
      await expect(page.getByText(/Live reads unavailable/)).toBeVisible();
      await expect(
        page.getByRole("button", { name: "Preview swap", exact: true }),
      ).toBeDisabled();
    }
    check(`Recovery scenario ${json(scenario)}`);
    await page.context().close();
  }
  page = await fixture({ chain: manifest.walletAddChain.chainId });
  await page
    .getByRole("button", { name: "Connect wallet", exact: true })
    .click();
  await page.getByRole("button", { name: "Preview swap", exact: true }).click();
  await expect(
    page.getByRole("button", { name: "Confirm buy in wallet" }),
  ).toBeVisible();
  await page.evaluate(() => (window.mock.reject = true));
  await page.getByRole("button", { name: "Confirm buy in wallet" }).click();
  await expect(page.getByRole("alert")).toContainText("declined");
  expect(await page.evaluate(() => window.mock.txs.length)).toBe(0);
  check(
    "Wallet transaction rejection leaves a recoverable error and sends no transaction",
  );
  await page.context().close();
  page = await fixture({ chain: manifest.walletAddChain.chainId });
  const tabTo = async (selector) => {
    for (let i = 0; i < 60; i++) {
      await page.keyboard.press("Tab");
      if (
        await page
          .locator(selector)
          .evaluate((el) => el === document.activeElement)
      )
        return;
    }
    throw Error(`Keyboard cannot reach ${selector}`);
  };
  await tabTo("#amount");
  await page.keyboard.press("Control+A");
  await page.keyboard.type("0.002");
  await page.keyboard.press("Tab");
  await expect(page.locator("#tolerance")).toBeFocused();
  await page.keyboard.press("Tab");
  await page.keyboard.press("Enter");
  await expect(page.getByText("0.59%", { exact: true })).toBeVisible();
  await page.keyboard.press("Tab");
  await expect(
    page.getByRole("button", { name: "Connect wallet to trade" }),
  ).toBeFocused();
  await page.screenshot({
    path: "../docs/evidence/keyboard-focus.png",
    fullPage: false,
  });
  report.screenshots.push("docs/evidence/keyboard-focus.png");
  await page.keyboard.press("Enter");
  await expect(
    page.getByRole("button", { name: "Confirm buy in wallet" }),
  ).toBeVisible();
  await tabTo(".trade button.primary");
  await page.keyboard.press("Enter");
  await expect(
    page.getByText("Buy WHAL confirmed.", { exact: false }),
  ).toBeVisible();
  check(
    "Keyboard-only primary buy flow: amount, tolerance, preview, connect, confirm; visible focus captured",
  );
  await page.context().close();
  expect(report.consoleErrors).toEqual([]);
  expect(report.resourceFailures).toEqual([]);
  expect(swapCount).toBeGreaterThanOrEqual(2);
  check(
    "No application console errors or local resource failures; all transaction sends were intercepted",
  );
  report.result = "pass";
} catch (e) {
  report.result = "fail";
  report.error = e.stack;
  console.error(e);
  if (page && !page.isClosed())
    await page.screenshot({
      path: "../docs/evidence/failure.png",
      fullPage: true,
    });
  process.exitCode = 1;
} finally {
  writeFileSync(
    "../docs/evidence/browser.json",
    JSON.stringify(report, null, 2) + "\n",
  );
  await browser.close();
}
