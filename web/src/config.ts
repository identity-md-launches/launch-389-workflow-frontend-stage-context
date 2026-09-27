import { keccak256, toHex, type Abi, type Address, type Hex } from "viem";
export type Provider = {
  request: (args: { method: string; params?: unknown[] }) => Promise<any>;
  on?: (event: string, fn: (...args: any[]) => void) => void;
  removeListener?: (event: string, fn: (...args: any[]) => void) => void;
};
declare global {
  interface Window {
    ethereum?: Provider;
  }
}
export interface Deployment {
  version: number;
  launchId: string;
  chainId: number;
  sourceCommit: string;
  attestationHash: string;
  contracts: {
    name: string;
    address: Address;
    abiHash: string;
    abiPath: string;
  }[];
  assets: { path: string; sha256: string }[];
  network: {
    chainId: number;
    name: string;
    testnet: boolean;
    rpcUrls: string[];
    explorer: string;
    nativeCurrency: { name: string; symbol: string; decimals: number };
    faucets: string[];
    uniswapV4: Record<string, Address>;
  };
  walletAddChain: {
    chainId: string;
    chainName: string;
    rpcUrls: string[];
    nativeCurrency: { name: string; symbol: string; decimals: number };
    blockExplorerUrls: string[];
  };
  pool: { fee: number; tickSpacing: number; pairedCurrency: Address };
  deploymentBlock: number;
  integrations: {
    poolSwapTest: Address;
    poolSwapTestSource: string;
    previewLens: Address;
    previewLensArtifact: string;
    abiPath: string;
  };
}
export interface Config {
  deployment: Deployment;
  token: { address: Address; abi: Abi };
  hook: { address: Address; abi: Abi };
  uniswap: Abi;
  lens: { abi: Abi; bytecode: Hex };
}
export function canonical(v: any): any {
  return Array.isArray(v)
    ? v.map(canonical)
    : v && typeof v === "object"
      ? Object.fromEntries(
          Object.keys(v)
            .sort()
            .map((k) => [k, canonical(v[k])]),
        )
      : v;
}
export const hashAbi = (abi: Abi) =>
  keccak256(toHex(JSON.stringify(canonical(abi)))).slice(2);
export function safePath(path: string) {
  if (!/^(?!\/)(?!.*\.\.)[a-zA-Z0-9_./-]+$/.test(path))
    throw Error("Invalid deployment asset path");
  return path;
}
export async function loadConfig(): Promise<Config> {
  const base = new URL("./", document.baseURI);
  const response = await fetch(new URL("imd-deployment.json", base), {
    cache: "no-store",
  });
  if (!response.ok)
    throw Error("Deployment manifest unavailable. Reload this page.");
  const d: Deployment = await response.json();
  if (
    d.version !== 1 ||
    d.chainId !== d.network.chainId ||
    Number(BigInt(d.walletAddChain.chainId)) !== d.chainId ||
    !d.network.testnet
  )
    throw Error(
      "Deployment network does not match. Transactions are disabled.",
    );
  async function asset(path: string) {
    const entry = d.assets.find((a) => a.path === path);
    if (!entry) throw Error(`Asset missing from manifest: ${path}`);
    const r = await fetch(new URL(safePath(path), base));
    if (!r.ok) throw Error(`Cannot load ${path}`);
    const bytes = await r.arrayBuffer();
    const hash = [
      ...new Uint8Array(await crypto.subtle.digest("SHA-256", bytes)),
    ]
      .map((b) => b.toString(16).padStart(2, "0"))
      .join("");
    if (hash !== entry.sha256)
      throw Error(`Asset integrity check failed: ${path}`);
    return JSON.parse(new TextDecoder().decode(bytes));
  }
  async function contract(name: string) {
    const c = d.contracts.find((c) => c.name === name);
    if (!c) throw Error(`Missing ${name}`);
    const abi = await asset(c.abiPath);
    if (hashAbi(abi) !== c.abiHash) throw Error(`ABI binding failed: ${name}`);
    return { address: c.address, abi };
  }
  const [token, hook, uniswap, lens] = await Promise.all([
    contract("WhaleToken"),
    contract("WhaleTaxHook"),
    asset(d.integrations.abiPath),
    asset(d.integrations.previewLensArtifact),
  ]);
  return { deployment: d, token, hook, uniswap, lens };
}
