import { readFileSync } from "node:fs";
import { keccak256, toHex } from "viem";
export const json = (p) =>
  JSON.parse(readFileSync(new URL(p, import.meta.url), "utf8"));
export const canonical = (v) =>
  Array.isArray(v)
    ? v.map(canonical)
    : v && typeof v === "object"
      ? Object.fromEntries(
          Object.keys(v)
            .sort()
            .map((k) => [k, canonical(v[k])]),
        )
      : v;
export const abiHash = (v) =>
  keccak256(toHex(JSON.stringify(canonical(v)))).slice(2);
export const handoff = json("../config/deployment.json");
export const network = json("../config/network.json");
export const integrations = json("../config/integrations.json");
