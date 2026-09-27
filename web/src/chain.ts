import {
  encodeAbiParameters,
  encodeFunctionData,
  decodeFunctionResult,
  decodeEventLog,
  keccak256,
  toHex,
  type Abi,
  type Address,
  type Hex,
} from "viem";
import type { Config, Provider } from "./config";
import { MIN_SQRT, MAX_SQRT, splitDelta, priceLimit } from "./math";
export interface Snapshot {
  block: bigint;
  sqrt: bigint;
  tick: number;
  lpFee: number;
  liquidity: bigint;
  decimals: number;
  symbol: string;
  supply: bigint;
  eth?: bigint;
  balance?: bigint;
  allowance?: bigint;
  fees: {
    currency: Address;
    accrued: bigint;
    collected: bigint;
    burned: bigint;
    claims: bigint;
  }[];
  rates: bigint[];
}
export interface Quote {
  amount: bigint;
  buy: boolean;
  block: bigint;
  time: number;
  delta: bigint;
  before: bigint;
  after: bigint;
  move: bigint;
  rate: bigint;
  fee: bigint;
  input: bigint;
  output: bigint;
  limit: bigint;
}
export interface TaxEvent {
  name: string;
  block: bigint;
  tx: Hex;
  index: number;
  currency: Address;
  fee: bigint;
  move?: bigint;
  rate?: bigint;
}
export class Chain {
  c: Config;
  wallet?: Provider;
  lastRpc = "";
  cursor = 0;
  constructor(c: Config) {
    this.c = c;
  }
  get d() {
    return this.c.deployment;
  }
  get key() {
    return {
      currency0: this.d.pool.pairedCurrency,
      currency1: this.c.token.address,
      fee: this.d.pool.fee,
      tickSpacing: this.d.pool.tickSpacing,
      hooks: this.c.hook.address,
    };
  }
  get poolId() {
    return keccak256(
      encodeAbiParameters(
        [
          {
            type: "tuple",
            components: [
              { name: "currency0", type: "address" },
              { name: "currency1", type: "address" },
              { name: "fee", type: "uint24" },
              { name: "tickSpacing", type: "int24" },
              { name: "hooks", type: "address" },
            ],
          },
        ],
        [this.key],
      ),
    );
  }
  async rpc(method: string, params: unknown[] = []): Promise<any> {
    let failure: unknown;
    for (let n = 0; n < this.d.network.rpcUrls.length; n++) {
      const index = (this.cursor + n) % this.d.network.rpcUrls.length;
      const url = this.d.network.rpcUrls[index];
      try {
        const r = await fetch(url, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
          signal: AbortSignal.timeout(12000),
        });
        if (!r.ok) throw Error(`RPC HTTP ${r.status}`);
        const payload = await r.json();
        if (payload.error)
          throw Object.assign(Error(payload.error.message), payload.error);
        if (payload.result === undefined) throw Error("RPC returned no result");
        this.cursor = index;
        this.lastRpc = new URL(url).hostname;
        return payload.result;
      } catch (e) {
        failure = e;
      }
    }
    if (this.wallet) {
      try {
        const chain = await this.wallet.request({ method: "eth_chainId" });
        if (Number(BigInt(chain)) === this.d.chainId) {
          const result =
            method === "eth_chainId"
              ? chain
              : await this.wallet.request({ method, params });
          this.lastRpc = "Connected wallet RPC";
          return result;
        }
      } catch (walletError) {
        // Preserve the public RPC's useful revert reason if fallback also fails.
        failure ??= walletError;
      }
    }
    throw (
      failure ??
      Error("No public RPC available. Connect a Sepolia wallet and retry.")
    );
  }
  async read(
    address: Address,
    abi: Abi,
    functionName: string,
    args: readonly unknown[] = [],
    block = "latest",
  ) {
    const data = encodeFunctionData({ abi, functionName, args });
    const result = await this.rpc("eth_call", [{ to: address, data }, block]);
    return decodeFunctionResult({ abi, functionName, data: result }) as any;
  }
  hook(name: string, args: readonly unknown[] = [], block = "latest") {
    return this.read(this.c.hook.address, this.c.hook.abi, name, args, block);
  }
  token(name: string, args: readonly unknown[] = [], block = "latest") {
    return this.read(this.c.token.address, this.c.token.abi, name, args, block);
  }
  async verify() {
    if (Number(BigInt(await this.rpc("eth_chainId"))) !== this.d.chainId)
      throw Error("RPC chain does not match the deployment.");
    if (BigInt(this.key.currency0) !== 0n)
      throw Error("This page supports the attested native ETH pool only.");
    const addresses = [
      ...this.d.contracts.map((c) => c.address),
      this.d.network.uniswapV4.poolManager,
      this.d.network.uniswapV4.stateView,
      this.d.network.uniswapV4.quoter,
      this.d.integrations.poolSwapTest,
    ];
    const codes = await Promise.all(
      addresses.map((a) => this.rpc("eth_getCode", [a, "latest"])),
    );
    if (codes.some((c) => !c || c === "0x" || c === "0x0"))
      throw Error(
        "A required contract has no code. Transactions are disabled.",
      );
    const [hookManager, routerManager] = await Promise.all([
      this.hook("poolManager"),
      this.read(this.d.integrations.poolSwapTest, this.c.uniswap, "manager"),
    ]);
    if (
      [hookManager, routerManager].some(
        (a) =>
          a.toLowerCase() !==
          this.d.network.uniswapV4.poolManager.toLowerCase(),
      )
    )
      throw Error("PoolManager binding mismatch.");
    return addresses.map((address, i) => ({
      address,
      codeBytes: (codes[i].length - 2) / 2,
    }));
  }
  async snapshot(account?: Address): Promise<Snapshot> {
    const block = BigInt(await this.rpc("eth_blockNumber")),
      tag = toHex(block);
    const view = this.d.network.uniswapV4.stateView;
    const [slot, liquidity, decimals, symbol, supply, fees, rates, wallet] =
      await Promise.all([
        this.read(view, this.c.uniswap, "getSlot0", [this.poolId], tag),
        this.read(view, this.c.uniswap, "getLiquidity", [this.poolId], tag),
        this.token("decimals", [], tag),
        this.token("symbol", [], tag),
        this.token("totalSupply", [], tag),
        Promise.all(
          [this.key.currency0, this.key.currency1].map(async (currency) => {
            const [accrued, collected, burned, claims] = await Promise.all(
              [
                "accruedFees",
                "totalFeesCollected",
                "totalFeesBurned",
                "claimsOf",
              ].map((f) => this.hook(f, [currency], tag)),
            );
            return { currency, accrued, collected, burned, claims };
          }),
        ),
        Promise.all(
          [0n, 250n, 500n].map((m) => this.hook("feeBpsForMove", [m], tag)),
        ),
        account
          ? Promise.all([
              this.rpc("eth_getBalance", [account, tag]).then(BigInt),
              this.token("balanceOf", [account], tag),
              this.token(
                "allowance",
                [account, this.d.integrations.poolSwapTest],
                tag,
              ),
            ])
          : undefined,
      ]);
    if (Number(decimals) !== 18 || symbol !== "WHAL")
      throw Error("Token metadata differs from the attested deployment.");
    if (rates.map(String).join(",") !== "30,265,500")
      throw Error("Hook fee curve differs from the approved source.");
    return {
      block,
      sqrt: slot[0],
      tick: slot[1],
      lpFee: slot[3],
      liquidity,
      decimals: Number(decimals),
      symbol,
      supply,
      fees,
      rates,
      eth: wallet?.[0],
      balance: wallet?.[1],
      allowance: wallet?.[2],
    };
  }
  async events(block: bigint): Promise<TaxEvent[]> {
    const start =
      block - 499n > BigInt(this.d.deploymentBlock)
        ? block - 499n
        : BigInt(this.d.deploymentBlock);
    if (start > block) return [];
    const logs = await this.rpc("eth_getLogs", [
      {
        address: this.c.hook.address,
        fromBlock: toHex(start),
        toBlock: toHex(block),
      },
    ]);
    return logs
      .flatMap((log: any) => {
        try {
          const decoded = decodeEventLog({
            abi: this.c.hook.abi,
            topics: log.topics,
            data: log.data,
          }) as any;
          const a = decoded.args;
          if (
            decoded.eventName === "WhaleTax" &&
            a.poolId.toLowerCase() !== this.poolId.toLowerCase()
          )
            return [];
          if (!["WhaleTax", "FeesBurned"].includes(decoded.eventName))
            return [];
          if (
            ![
              this.key.currency0.toLowerCase(),
              this.key.currency1.toLowerCase(),
            ].includes(a.currency.toLowerCase())
          )
            return [];
          return [
            {
              name: decoded.eventName,
              block: BigInt(log.blockNumber),
              tx: log.transactionHash,
              index: Number(BigInt(log.logIndex)),
              currency: a.currency,
              fee: a.fee ?? a.amount,
              move: a.moveBps,
              rate: a.feeBps,
            },
          ];
        } catch {
          return [];
        }
      })
      .sort((a: TaxEvent, b: TaxEvent) =>
        a.block === b.block ? b.index - a.index : a.block > b.block ? -1 : 1,
      )
      .slice(0, 12);
  }
  async quote(amount: bigint, buy: boolean, tolerance: string): Promise<Quote> {
    const block = BigInt(await this.rpc("eth_blockNumber")),
      tag = toHex(block);
    const at = this.d.integrations.previewLens;
    if ((await this.rpc("eth_getCode", [at, tag])) !== "0x")
      throw Error("Simulation address is occupied. Preview disabled.");
    const params = {
      zeroForOne: buy,
      amountSpecified: -amount,
      sqrtPriceLimitX96: buy ? MIN_SQRT : MAX_SQRT,
    };
    const data = encodeFunctionData({
      abi: this.c.lens.abi,
      functionName: "quote",
      args: [
        this.d.network.uniswapV4.poolManager,
        this.d.network.uniswapV4.stateView,
        this.key,
        params,
      ],
    });
    let raw;
    try {
      raw = await this.rpc("eth_call", [
        { to: at, data, gas: toHex(8000000) },
        tag,
        { [at]: { code: this.c.lens.bytecode } },
      ]);
    } catch (e) {
      throw Error(
        `Fee preview failed. The RPC must support eth_call code overrides. ${e instanceof Error ? e.message : ""}`,
      );
    }
    const [delta, before, after, move, rate, fee] = decodeFunctionResult({
      abi: this.c.lens.abi,
      functionName: "quote",
      data: raw,
    }) as readonly bigint[];
    const legs = splitDelta(delta),
      input = -(buy ? legs[0] : legs[1]),
      output = buy ? legs[1] : legs[0];
    if (input <= 0n || output <= 0n)
      throw Error("No executable liquidity for this direction and amount.");
    if (input !== amount)
      throw Error(
        "This size exceeds available liquidity. Enter a smaller amount.",
      );
    const quoted = await this.read(
      this.d.network.uniswapV4.quoter,
      this.c.uniswap,
      "quoteExactInputSingle",
      [
        {
          poolKey: this.key,
          zeroForOne: buy,
          exactAmount: amount,
          hookData: "0x",
        },
      ],
      tag,
    );
    if (quoted[0] !== output)
      throw Error(
        "Independent quote disagrees with the fee simulation. Refresh and try again.",
      );
    return {
      amount,
      buy,
      block,
      time: Date.now(),
      delta,
      before,
      after,
      move,
      rate,
      fee,
      input,
      output,
      limit: priceLimit(after, tolerance, buy),
    };
  }
  async assertWallet(account: Address) {
    if (!this.wallet) throw Error("Connect a browser wallet.");
    const chain = await this.wallet.request({ method: "eth_chainId" });
    const accounts = await this.wallet.request({ method: "eth_accounts" });
    if (Number(BigInt(chain)) !== this.d.chainId)
      throw Error(`Switch to ${this.d.network.name} before continuing.`);
    if (accounts[0]?.toLowerCase() !== account.toLowerCase())
      throw Error("Wallet account changed. Refresh and try again.");
  }
  async send(
    account: Address,
    to: Address,
    abi: Abi,
    functionName: string,
    args: readonly unknown[],
    value = 0n,
  ) {
    await this.assertWallet(account);
    await this.verify();
    const tx = {
      from: account,
      to,
      data: encodeFunctionData({ abi, functionName, args }),
      value: toHex(value),
    };
    await this.rpc("eth_call", [tx, "latest"]);
    const gas = await this.rpc("eth_estimateGas", [tx]);
    await this.assertWallet(account);
    return (await this.wallet!.request({
      method: "eth_sendTransaction",
      params: [{ ...tx, gas, chainId: toHex(this.d.chainId) }],
    })) as Hex;
  }
  async swap(account: Address, q: Quote) {
    if (Date.now() - q.time > 60000)
      throw Error("Preview expired. Simulate this amount again.");
    const args = [
      this.key,
      {
        zeroForOne: q.buy,
        amountSpecified: -q.amount,
        sqrtPriceLimitX96: q.limit,
      },
      { takeClaims: false, settleUsingBurn: false },
      "0x",
    ];
    return this.send(
      account,
      this.d.integrations.poolSwapTest,
      this.c.uniswap,
      "swap",
      args,
      q.buy ? q.amount : 0n,
    );
  }
  approve(account: Address, amount: bigint) {
    return this.send(
      account,
      this.c.token.address,
      this.c.token.abi,
      "approve",
      [this.d.integrations.poolSwapTest, amount],
    );
  }
  burn(account: Address, currency: Address) {
    return this.send(
      account,
      this.c.hook.address,
      this.c.hook.abi,
      "burnFees",
      [currency],
    );
  }
  async receipt(hash: Hex) {
    for (let i = 0; i < 60; i++) {
      const receipt = await this.rpc("eth_getTransactionReceipt", [hash]);
      if (receipt) {
        if (BigInt(receipt.status) !== 1n)
          throw Error(
            "Transaction reverted on chain. Refresh and review before retrying.",
          );
        return receipt;
      }
      await new Promise((r) => setTimeout(r, 3000));
    }
    throw Error(
      "Confirmation is taking longer than expected. Check the transaction explorer before retrying.",
    );
  }
}
export async function switchChain(provider: Provider, c: Config) {
  const chainId = toHex(c.deployment.chainId);
  try {
    await provider.request({
      method: "wallet_switchEthereumChain",
      params: [{ chainId }],
    });
  } catch (e) {
    const error = e as {
      code?: number;
      message?: string;
      data?: { originalError?: { code?: number } };
    };
    if (
      error.code !== 4902 &&
      error.data?.originalError?.code !== 4902 &&
      !/unknown chain|unrecognized chain|not added/i.test(error.message ?? "")
    )
      throw e;
    await provider.request({
      method: "wallet_addEthereumChain",
      params: [c.deployment.walletAddChain],
    });
    await provider.request({
      method: "wallet_switchEthereumChain",
      params: [{ chainId }],
    });
  }
}
