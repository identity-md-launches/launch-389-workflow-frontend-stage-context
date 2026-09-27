import { formatUnits, parseUnits } from "viem";
export const MIN_SQRT = 4295128740n;
export const MAX_SQRT = 1461446703485210103287273052203988822378723970341n;
export function amountOf(text: string, decimals: number) {
  if (
    !/^\d+(\.\d+)?$/.test(text) ||
    (text.split(".")[1]?.length ?? 0) > decimals
  )
    throw Error(
      `Enter a positive amount with at most ${decimals} decimal places.`,
    );
  const value = parseUnits(text, decimals);
  if (value <= 0n || value >= 2n ** 127n)
    throw Error("Enter a positive amount below the swap limit.");
  return value;
}
export function splitDelta(delta: bigint) {
  return [
    BigInt.asIntN(128, delta >> 128n),
    BigInt.asIntN(128, delta),
  ] as const;
}
export function sqrt(n: bigint): bigint {
  if (n < 0n) throw Error("Negative square root");
  if (n < 2n) return n;
  let x = n,
    y = (x + 1n) / 2n;
  while (y < x) {
    x = y;
    y = (x + n / x) / 2n;
  }
  return x;
}
export function priceLimit(after: bigint, tolerance: string, buy: boolean) {
  const bps = amountOf(tolerance, 2);
  if (bps > 500n) throw Error("Use a price tolerance from 0.01% to 5%.");
  const limit = sqrt((after * after * (10000n + (buy ? -bps : bps))) / 10000n);
  return limit < MIN_SQRT ? MIN_SQRT : limit > MAX_SQRT ? MAX_SQRT : limit;
}
export const feeForMove = (m: number) =>
  30 + Math.floor((470 * Math.min(Math.max(m, 0), 500)) / 500);
export function display(value: bigint | undefined, decimals = 18, digits = 6) {
  if (value === undefined) return "—";
  const n = Number(formatUnits(value, decimals));
  if (n > 0 && n < 10 ** -digits) return `< ${10 ** -digits}`;
  return new Intl.NumberFormat("en", { maximumFractionDigits: digits }).format(
    n,
  );
}
export const poolPrice = (s: bigint, tokenDecimals: number) =>
  (Number(s) ** 2 / 2 ** 192) * 10 ** (18 - tokenDecimals);
export function errorText(e: unknown): string {
  const v = e as { code?: number; shortMessage?: string; message?: string };
  if (v.code === 4001 || /rejected|denied/i.test(v.message ?? ""))
    return "Request declined in your wallet. You can try again.";
  return (
    v.shortMessage ??
    v.message ??
    "Request failed. Check your connection and try again."
  ).slice(0, 420);
}
