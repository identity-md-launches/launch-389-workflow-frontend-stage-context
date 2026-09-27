import { useCallback, useEffect, useRef, useState } from "react";
import { isAddress, type Address, type Hex } from "viem";
import { loadConfig, type Config } from "./config";
import {
  Chain,
  switchChain,
  type Snapshot,
  type Quote,
  type TaxEvent,
} from "./chain";
import {
  amountOf,
  display,
  errorText,
  feeForMove,
  poolPrice,
  priceLimit,
} from "./math";
const short = (s: string) => `${s.slice(0, 6)}…${s.slice(-4)}`;
function Whale() {
  return (
    <svg aria-hidden="true" viewBox="0 0 48 48">
      <path
        d="M7 21c0 12 11 20 23 13 6-4 7-11 7-11 5-1 7-5 6-10-4 0-7 2-8 5-3-5-9-8-16-6-7 1-12 4-12 9Z"
        fill="currentColor"
      />
      <circle cx="15" cy="22" r="2" fill="var(--paper)" />
      <path
        d="M17 8V3m5 6 3-4"
        fill="none"
        stroke="currentColor"
        strokeWidth="2.5"
        strokeLinecap="round"
      />
    </svg>
  );
}
function Curve({ move }: { move?: bigint }) {
  const x = (v: number) => 78 + (v / 600) * 420,
    y = (v: number) => 178 - ((v - 30) / 470) * 138;
  const m = move === undefined ? undefined : Math.min(Number(move), 600);
  return (
    <figure className="curve">
      <svg
        viewBox="0 0 540 235"
        role="img"
        aria-labelledby="curve-title curve-desc"
      >
        <title id="curve-title">Hook fee by pool price move</title>
        <desc id="curve-desc">
          0.30% at zero price move, 2.65% at 2.5% price move, 5% at and above 5%
          price move. Rounded down to whole basis points.
        </desc>
        {[30, 265, 500].map((v) => (
          <g key={v}>
            <line x1="78" x2="504" y1={y(v)} y2={y(v)} className="gridline" />
            <text x="2" y={y(v) + 4}>
              {(v / 100).toFixed(2)}%
            </text>
          </g>
        ))}
        <path
          d={`M78 178 L${x(500)} 40 L498 40 L498 178 Z`}
          className="curve-area"
        />
        <path d={`M78 178 L${x(500)} 40 L498 40`} className="curve-line" />
        {[0, 250, 500].map((v) => (
          <g key={v}>
            <circle
              cx={x(v)}
              cy={y(feeForMove(v))}
              r="4"
              className="curve-dot"
            />
            <text x={x(v)} y="204" textAnchor="middle">
              {v / 100}%
            </text>
          </g>
        ))}
        {m !== undefined && (
          <g>
            <line
              x1={x(m)}
              x2={x(m)}
              y1="28"
              y2="182"
              className="preview-line"
            />
            <circle
              cx={x(m)}
              cy={y(feeForMove(m))}
              r="7"
              className="preview-dot"
            />
          </g>
        )}
        <text x="273" y="230" textAnchor="middle">
          Pool price move
        </text>
      </svg>
      <figcaption>
        Hook fee on output · 0.30% → 5.00%
        <span>Separate from the pool’s LP fee</span>
      </figcaption>
    </figure>
  );
}
export default function App() {
  const [config, setConfig] = useState<Config>();
  const [engine, setEngine] = useState<Chain>();
  const [account, setAccount] = useState<Address>();
  const [walletChain, setWalletChain] = useState<number>();
  const [state, setState] = useState<Snapshot>();
  const [events, setEvents] = useState<TaxEvent[]>([]);
  const [eventError, setEventError] = useState("");
  const [verified, setVerified] = useState(false);
  const [loading, setLoading] = useState(true);
  const [readError, setReadError] = useState("");
  const [error, setError] = useState("");
  const [status, setStatus] = useState("");
  const [busy, setBusy] = useState("");
  const [buy, setBuy] = useState(true);
  const [amount, setAmount] = useState("0.001");
  const [tolerance, setTolerance] = useState("0.5");
  const [quote, setQuote] = useState<Quote>();
  const [now, setNow] = useState(Date.now());
  const [tx, setTx] = useState<Hex>();
  const [burnCurrency, setBurnCurrency] = useState("0");
  const [burnConsent, setBurnConsent] = useState(false);
  const [recipient, setRecipient] = useState("");
  const [transferAmount, setTransferAmount] = useState("");
  const generation = useRef(0);
  const inputRef = useRef<HTMLInputElement>(null);
  const refreshId = useRef(0);
  const busyRef = useRef(false);
  useEffect(() => {
    loadConfig()
      .then((c) => {
        setConfig(c);
        setEngine(new Chain(c));
      })
      .catch((e) => {
        setReadError(errorText(e));
        setLoading(false);
      });
  }, []);
  const refresh = useCallback(async () => {
    if (!engine) return;
    const id = ++refreshId.current;
    setLoading(true);
    try {
      await engine.verify();
      const s = await engine.snapshot(account);
      if (id !== refreshId.current) return;
      setVerified(true);
      setState(s);
      setReadError("");
      try {
        const logs = await engine.events(s.block);
        if (id === refreshId.current) {
          setEvents(logs);
          setEventError("");
        }
      } catch (e) {
        if (id === refreshId.current) {
          setEvents([]);
          setEventError(
            `Activity unavailable. ${errorText(e)} Use Refresh to retry.`,
          );
        }
      }
    } catch (e) {
      if (id === refreshId.current) {
        setVerified(false);
        setReadError(
          `Live reads unavailable. ${errorText(e)} Use Refresh to retry.`,
        );
      }
    } finally {
      if (id === refreshId.current) setLoading(false);
    }
  }, [engine, account]);
  useEffect(() => {
    void refresh();
    const timer = setInterval(() => void refresh(), 30000);
    return () => {
      clearInterval(timer);
      refreshId.current++;
    };
  }, [refresh]);
  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(timer);
  }, []);
  const invalidate = useCallback(() => {
    generation.current++;
    setQuote(undefined);
    setError("");
  }, []);
  useEffect(() => {
    if (!engine || !window.ethereum) return;
    const provider = window.ethereum;
    const accounts = (a: string[]) => {
      invalidate();
      setState((s) =>
        s
          ? { ...s, balance: undefined, allowance: undefined, eth: undefined }
          : s,
      );
      setAccount(a[0] as Address | undefined);
      engine.wallet = a[0] ? provider : undefined;
    };
    const chain = (c: string) => {
      invalidate();
      setWalletChain(Number(BigInt(c)));
    };
    const disconnect = () => {
      accounts([]);
      setWalletChain(undefined);
    };
    provider.on?.("accountsChanged", accounts);
    provider.on?.("chainChanged", chain);
    provider.on?.("disconnect", disconnect);
    // No unsolicited account request. Existing authorizations are restored silently.
    Promise.all([
      provider.request({ method: "eth_accounts" }),
      provider.request({ method: "eth_chainId" }),
    ])
      .then(([a, c]) => {
        accounts(a);
        chain(c);
      })
      .catch(() => {});
    return () => {
      provider.removeListener?.("accountsChanged", accounts);
      provider.removeListener?.("chainChanged", chain);
      provider.removeListener?.("disconnect", disconnect);
    };
  }, [engine, invalidate]);
  const run = async (label: string, fn: () => Promise<void>) => {
    if (busyRef.current) return;
    busyRef.current = true;
    setBusy(label);
    setError("");
    try {
      await fn();
    } catch (e) {
      setError(errorText(e));
      setStatus("");
    } finally {
      busyRef.current = false;
      setBusy("");
    }
  };
  const connect = () =>
    run("Connecting", async () => {
      if (!window.ethereum)
        throw Error(
          "No browser wallet found. Install a browser wallet with Sepolia support, then reload this page.",
        );
      const accounts = await window.ethereum.request({
        method: "eth_requestAccounts",
      });
      if (!accounts[0])
        throw Error("No account selected. Open your wallet and try again.");
      engine!.wallet = window.ethereum;
      setAccount(accounts[0]);
      setWalletChain(
        Number(
          BigInt(await window.ethereum.request({ method: "eth_chainId" })),
        ),
      );
      setStatus("Wallet connected.");
    });
  const switchNetwork = () =>
    run("Switching network", async () => {
      await switchChain(window.ethereum!, config!);
      setWalletChain(
        Number(
          BigInt(await window.ethereum!.request({ method: "eth_chainId" })),
        ),
      );
      invalidate();
      setStatus("Network switched. Preview your swap.");
    });
  const wrongChain = !!account && walletChain !== config?.deployment.chainId;
  const ready = !!account && !wrongChain && verified && !busy;
  const expired = !!quote && now - quote.time > 60000;
  let typed = 0n;
  try {
    typed = amountOf(amount, buy ? 18 : (state?.decimals ?? 18));
  } catch {
    /* validated on submit */
  }
  const insufficient =
    !!account &&
    !!state &&
    typed > (buy ? (state.eth ?? 0n) : (state.balance ?? 0n));
  const approval = !!quote && !buy && (state?.allowance ?? 0n) < quote.amount;
  const preview = () =>
    run("Simulating swap", async () => {
      let size;
      try {
        size = amountOf(amount, buy ? 18 : state!.decimals);
      } catch (e) {
        inputRef.current?.focus();
        throw e;
      }
      try {
        priceLimit(2n ** 96n, tolerance, buy);
      } catch (e) {
        document.getElementById("tolerance")?.focus();
        throw e;
      }
      const id = ++generation.current;
      setQuote(undefined);
      const q = await engine!.quote(size, buy, tolerance);
      if (id !== generation.current) return;
      setQuote(q);
      setStatus(
        "Preview ready. Review the fee and price limit before continuing.",
      );
    });
  const transact = async (label: string, send: () => Promise<Hex>) => {
    setStatus(`${label}: simulating before wallet confirmation.`);
    setTx(undefined);
    const hash = await send();
    setTx(hash);
    setStatus(`${label} submitted. Waiting for confirmation…`);
    await engine!.receipt(hash);
    invalidate();
    setStatus(`${label} confirmed.`);
    setBurnConsent(false);
    await refresh();
  };
  const d = config?.deployment;
  const decimals = state?.decimals ?? 18;
  return (
    <>
      <a className="skip" href="#main">
        Skip to content
      </a>
      <header className="header">
        <a className="brand" href="#main">
          <Whale />
          <span>
            whale tax
            <span className="brand-sub">An experiment in price impact</span>
          </span>
        </a>
        <div className="wallet">
          <span className="network-pill">
            <span className="dot" /> {d?.network.name ?? "Sepolia"} testnet
          </span>
          <button
            className="outline"
            disabled={!engine || !!busy}
            onClick={
              account
                ? () => {
                    invalidate();
                    setAccount(undefined);
                    setWalletChain(undefined);
                    engine!.wallet = undefined;
                    setStatus("Wallet disconnected from this page.");
                  }
                : connect
            }
          >
            {account ? `${short(account)} · Disconnect` : "Connect wallet"}
          </button>
        </div>
      </header>
      <main id="main">
        <div className="intro">
          <div>
            <p className="eyebrow">Whale Tax / WHAL–ETH / Uniswap v4</p>
            <h1>Every trade makes a move.</h1>
            <p className="lead">
              The bigger the price move, the higher the hook fee.
              <br />
              Explore the curve. Preview your impact. Trade on Sepolia.
            </p>
          </div>
          <span className="edition">
            POOL EXPERIMENT
            <br />
            <strong>001 / WHAL</strong>
          </span>
        </div>
        <div className="read-status">
          <span>
            <span className={`dot ${verified ? "" : "muted"}`} />
            {loading
              ? "Checking live pool…"
              : verified
                ? `Live · block ${state?.block.toLocaleString()}`
                : "Live connection unavailable"}
          </span>
          <button
            onClick={() => void refresh()}
            disabled={!engine || loading || !!busy}
          >
            Refresh
          </button>
        </div>
        {readError && (
          <p role="alert" className="notice error">
            {readError}
          </p>
        )}
        {wrongChain && (
          <div className="notice warning">
            <span>
              Wallet is on a different network. Switch to {d?.network.name} to
              transact.
            </span>
            <button disabled={!!busy} onClick={switchNetwork}>
              Switch to {d?.network.name}
            </button>
          </div>
        )}
        <div className="workspace">
          <section className="market" aria-labelledby="pool-heading">
            <div className="section-heading">
              <h2 id="pool-heading">The pool</h2>
              <span className="small-label">WHAL per ETH</span>
            </div>
            <p className="price">
              {state
                ? new Intl.NumberFormat("en", {
                    maximumFractionDigits: 2,
                  }).format(poolPrice(state.sqrt, decimals))
                : "—"}
              <span>
                WHAL <span className="muted-text">/ 1 ETH</span>
              </span>
            </p>
            <dl className="metrics">
              <div>
                <dt>Hook fee range</dt>
                <dd>
                  0.30–5.00<span>%</span>
                </dd>
              </div>
              <div>
                <dt>Pool LP fee</dt>
                <dd>
                  {state ? (state.lpFee / 10000).toFixed(2) : "0.30"}
                  <span>%</span>
                </dd>
              </div>
              <div>
                <dt>Fixed supply</dt>
                <dd>
                  {state ? display(state.supply, decimals, 0) : "1,000,000,000"}
                  <span> WHAL</span>
                </dd>
              </div>
            </dl>
            <div className="curve-heading">
              <div>
                <p className="eyebrow">Understand the mechanism</p>
                <h2>A fee that follows your impact</h2>
              </div>
              <span className="curve-badge">Capped at 5%</span>
            </div>
            <Curve move={quote?.move} />
            <p className="explanation">
              Small moves start at <strong>0.30%</strong>. A{" "}
              <strong>2.5%</strong> pool price move pays <strong>2.65%</strong>.
              At a <strong>5%</strong> move, the hook fee reaches its cap.
            </p>
            <p className="small muted-text">
              Tax applies to each swap. Splitting a trade across swaps or blocks
              can lower it; this is part of the design.
            </p>
          </section>
          <section className="trade card" aria-labelledby="trade-heading">
            <div className="section-heading">
              <h2 id="trade-heading">Make a move</h2>
              <span className="small-label">Test tokens only</span>
            </div>
            <div className="segmented" aria-label="Swap direction">
              <button
                aria-pressed={buy}
                disabled={!!busy}
                onClick={() => {
                  setBuy(true);
                  setAmount("0.001");
                  invalidate();
                }}
              >
                Buy WHAL
              </button>
              <button
                aria-pressed={!buy}
                disabled={!!busy}
                onClick={() => {
                  setBuy(false);
                  setAmount("100");
                  invalidate();
                }}
              >
                Sell WHAL
              </button>
            </div>
            <form
              onSubmit={(e) => {
                e.preventDefault();
                void preview();
              }}
            >
              <label className="amount-box" htmlFor="amount">
                <span>You pay</span>
                <span className="input-row">
                  <input
                    ref={inputRef}
                    id="amount"
                    name="amount"
                    inputMode="decimal"
                    autoComplete="off"
                    value={amount}
                    disabled={!!busy}
                    aria-describedby="balance amount-hint action-error"
                    aria-invalid={!!error && typed === 0n}
                    onChange={(e) => {
                      setAmount(e.target.value);
                      invalidate();
                    }}
                  />
                  <strong>{buy ? "ETH" : "WHAL"}</strong>
                </span>
                <span id="balance" className="small muted-text">
                  {account
                    ? `Balance: ${display(buy ? state?.eth : state?.balance, buy ? 18 : decimals)} ${buy ? "ETH" : "WHAL"}`
                    : "Connect a wallet to see your balance"}
                </span>
              </label>
              <p id="amount-hint" className="small muted-text">
                Exact input · the hook fee is taken from your output.
              </p>
              <div className="tolerance">
                <label htmlFor="tolerance">Extra pool price tolerance</label>
                <div>
                  <input
                    id="tolerance"
                    inputMode="decimal"
                    value={tolerance}
                    disabled={!!busy}
                    onChange={(e) => {
                      setTolerance(e.target.value);
                      invalidate();
                    }}
                    aria-describedby="limit-note"
                  />
                  <span>%</span>
                </div>
              </div>
              <div className="output">
                <span>Estimated receive</span>
                <strong>
                  {quote ? display(quote.output, buy ? decimals : 18) : "—"}{" "}
                  <small>{buy ? "WHAL" : "ETH"}</small>
                </strong>
              </div>
              <dl className="quote-details">
                <div>
                  <dt>Price move</dt>
                  <dd>{quote ? `${Number(quote.move) / 100}%` : "—"}</dd>
                </div>
                <div>
                  <dt>Hook fee</dt>
                  <dd>
                    {quote
                      ? `${Number(quote.rate) / 100}% · ${display(quote.fee, buy ? decimals : 18)} ${buy ? "WHAL" : "ETH"}`
                      : "Simulate to preview"}
                  </dd>
                </div>
                <div>
                  <dt>Pool LP fee</dt>
                  <dd>
                    {state ? (state.lpFee / 10000).toFixed(2) : "0.30"}% of
                    input
                  </dd>
                </div>
                {quote && (
                  <>
                    <div>
                      <dt>Pool price after</dt>
                      <dd>
                        {new Intl.NumberFormat("en", {
                          maximumFractionDigits: 2,
                        }).format(poolPrice(quote.after, decimals))}{" "}
                        WHAL/ETH
                      </dd>
                    </div>
                    <div>
                      <dt>{buy ? "Lowest" : "Highest"} pool price</dt>
                      <dd>
                        {new Intl.NumberFormat("en", {
                          maximumFractionDigits: 2,
                        }).format(poolPrice(quote.limit, decimals))}{" "}
                        WHAL/ETH
                      </dd>
                    </div>
                  </>
                )}
              </dl>
              <p id="limit-note" className="small warning-text">
                PoolSwapTest enforces a pool price limit, not a minimum received
                amount. Partial fills are possible; unused input stays with you
                or is refunded. Estimates include the hook fee.
              </p>
              {quote && (
                <p className="small quote-age">
                  {expired
                    ? "Preview expired. Simulate again."
                    : `Simulated at block ${quote.block} · valid for ${Math.min(60, Math.max(0, 60 - Math.floor((now - quote.time) / 1000)))}s`}
                </p>
              )}
              {insufficient && (
                <p className="small warning-text">
                  Insufficient {buy ? "ETH" : "WHAL"} balance. You also need ETH
                  for network fees.
                </p>
              )}
              <button
                className={quote && !expired ? "outline full" : "primary full"}
                type="submit"
                disabled={!verified || !!busy}
              >
                {busy === "Simulating swap"
                  ? "Simulating swap…"
                  : quote
                    ? "Refresh preview"
                    : "Preview swap"}
                <span aria-hidden="true">↗</span>
              </button>
            </form>
            {!account ? (
              <button
                className={
                  quote && !expired ? "primary full next" : "outline full next"
                }
                disabled={!engine || !!busy}
                onClick={connect}
              >
                Connect wallet to trade
              </button>
            ) : wrongChain ? (
              <p className="small muted-text">
                Use the network switch above to continue.
              </p>
            ) : (
              quote &&
              !expired && (
                <>
                  {approval ? (
                    <button
                      className="primary full next"
                      disabled={!ready || insufficient}
                      onClick={() =>
                        run("Approving WHAL", () =>
                          transact("WHAL approval", () =>
                            engine!.approve(account, quote.amount),
                          ),
                        )
                      }
                    >
                      Approve {display(quote.amount, decimals)} WHAL
                    </button>
                  ) : (
                    <button
                      className="primary full next"
                      disabled={!ready || insufficient}
                      onClick={() =>
                        run("Confirming swap", () =>
                          transact(buy ? "Buy WHAL" : "Sell WHAL", () =>
                            engine!.swap(account, quote),
                          ),
                        )
                      }
                    >
                      {busy === "Confirming swap"
                        ? "Confirming swap…"
                        : buy
                          ? "Confirm buy in wallet"
                          : "Confirm sell in wallet"}
                    </button>
                  )}
                  {approval && (
                    <p className="small muted-text">
                      Step 1: approve this amount for PoolSwapTest. Step 2:
                      refresh the preview and confirm your sell.
                    </p>
                  )}
                </>
              )
            )}
            <p className="trade-foot">Uniswap v4 · Sepolia · No platform fee</p>
          </section>
        </div>
        <div className="feedback" aria-live="polite" role="status">
          {busy && <span className="working">{busy}… </span>}
          {status}
          {tx && d && (
            <a
              href={`${d.network.explorer}/tx/${tx}`}
              target="_blank"
              rel="noreferrer"
            >
              View transaction ↗
            </a>
          )}
        </div>
        {error && (
          <p id="action-error" role="alert" className="notice error">
            {error}
          </p>
        )}
        <div className="lower-grid">
          <section aria-labelledby="fees-heading">
            <div className="section-heading">
              <div>
                <p className="eyebrow">Where the fees go</p>
                <h2 id="fees-heading">Collected. Accounted for.</h2>
              </div>
            </div>
            <p className="small muted-text">
              The hook holds fee claims. Anyone can send those claims to the
              dead address. This does not reduce WHAL’s total supply.
            </p>
            <div
              className="fee-table"
              tabIndex={0}
              role="region"
              aria-label="Fee accounting"
            >
              <table>
                <thead>
                  <tr>
                    <th>Currency</th>
                    <th>Unburned</th>
                    <th>Lifetime collected</th>
                    <th>Sent to dead</th>
                  </tr>
                </thead>
                <tbody>
                  {[0, 1].map((i) => (
                    <tr key={i}>
                      <th>{i ? "WHAL" : "ETH"}</th>
                      <td>
                        {display(state?.fees[i].accrued, i ? decimals : 18)}
                      </td>
                      <td>
                        {display(state?.fees[i].collected, i ? decimals : 18)}
                      </td>
                      <td>
                        {display(state?.fees[i].burned, i ? decimals : 18)}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <p className="table-hint">
              Scroll the table to see all balances on narrow screens.
            </p>
            <details>
              <summary>Send accrued claims to the dead address</summary>
              <div className="details-body">
                <p className="small">
                  This is permanent. No claims go to your wallet. Balances
                  aggregate all native-ETH pools using this hook.
                </p>
                <label htmlFor="burn-currency">Fee currency</label>
                <select
                  id="burn-currency"
                  value={burnCurrency}
                  disabled={!!busy}
                  onChange={(e) => {
                    setBurnCurrency(e.target.value);
                    setBurnConsent(false);
                  }}
                >
                  <option value="0">ETH</option>
                  <option value="1">WHAL</option>
                </select>
                <label className="checkbox">
                  <input
                    type="checkbox"
                    checked={burnConsent}
                    disabled={!!busy}
                    onChange={(e) => setBurnConsent(e.target.checked)}
                  />
                  I understand the claims will be sent permanently to the dead
                  address.
                </label>
                <button
                  className="outline"
                  disabled={
                    !ready ||
                    !burnConsent ||
                    !state?.fees[Number(burnCurrency)].accrued
                  }
                  onClick={() =>
                    run("Burning fee claims", () =>
                      transact("Fee claim burn", () =>
                        engine!.burn(
                          account!,
                          state!.fees[Number(burnCurrency)].currency,
                        ),
                      ),
                    )
                  }
                >
                  Burn {burnCurrency === "0" ? "ETH" : "WHAL"} fee claims
                </button>
                <p className="small muted-text">
                  {!account
                    ? "Connect a wallet to burn claims."
                    : !state?.fees[Number(burnCurrency)].accrued
                      ? "No accrued claims in this currency."
                      : "Your wallet will ask you to confirm the network fee."}
                </p>
              </div>
            </details>
          </section>
          <section aria-labelledby="activity-heading">
            <div className="section-heading">
              <div>
                <p className="eyebrow">On-chain observability</p>
                <h2 id="activity-heading">Recent activity</h2>
              </div>
              <span className="small-label">Last 500 blocks</span>
            </div>
            {eventError ? (
              <p className="small warning-text">{eventError}</p>
            ) : events.length ? (
              <ul className="events">
                {events.map((e) => (
                  <li key={`${e.tx}-${e.index}`}>
                    <div>
                      <strong>
                        {e.name === "WhaleTax"
                          ? `${Number(e.rate) / 100}% hook fee`
                          : "Fee claims burned"}
                      </strong>
                      <span>
                        {display(
                          e.fee,
                          e.currency.toLowerCase() ===
                            config?.token.address.toLowerCase()
                            ? decimals
                            : 18,
                        )}{" "}
                        {e.currency.toLowerCase() ===
                        config?.token.address.toLowerCase()
                          ? "WHAL"
                          : "ETH"}
                        {e.move !== undefined
                          ? ` · ${Number(e.move) / 100}% move`
                          : ""}
                      </span>
                    </div>
                    <a
                      href={`${d?.network.explorer}/tx/${e.tx}`}
                      target="_blank"
                      rel="noreferrer"
                    >
                      Block {e.block.toString()} ↗
                    </a>
                  </li>
                ))}
              </ul>
            ) : (
              <div className="empty">
                <span aria-hidden="true">≋</span>
                <p>
                  {verified
                    ? "No hook activity in this window."
                    : "Waiting for live hook activity."}
                </p>
                <p className="small muted-text">
                  {verified
                    ? "New swaps and fee burns will appear here. Refresh to check again."
                    : "Connect to the public RPC to load recent swaps and fee burns."}
                </p>
              </div>
            )}
          </section>
        </div>
        <details className="technical">
          <summary>Pool details & wallet tools</summary>
          <div className="technical-grid">
            <div>
              <h2>Deployment details</h2>
              <p className="small">
                No owner, admin, pause or upgrade. The deployed hook enables
                beforeSwap, afterSwap and afterSwapReturnDelta.
              </p>
              <dl className="deployment-list">
                {d?.contracts.map((c) => (
                  <div key={c.name}>
                    <dt>{c.name}</dt>
                    <dd>
                      <a
                        href={`${d.network.explorer}/address/${c.address}`}
                        target="_blank"
                        rel="noreferrer"
                      >
                        {c.address} ↗
                      </a>
                    </dd>
                  </div>
                ))}
                {d &&
                  ["stateView", "poolManager", "quoter"].map((n) => (
                    <div key={n}>
                      <dt>{n}</dt>
                      <dd>
                        <a
                          href={`${d.network.explorer}/address/${d.network.uniswapV4[n]}`}
                          target="_blank"
                          rel="noreferrer"
                        >
                          {d.network.uniswapV4[n]} ↗
                        </a>
                      </dd>
                    </div>
                  ))}
                {d && (
                  <div>
                    <dt>PoolSwapTest</dt>
                    <dd>
                      <a
                        href={`${d.network.explorer}/address/${d.integrations.poolSwapTest}`}
                        target="_blank"
                        rel="noreferrer"
                      >
                        {d.integrations.poolSwapTest} ↗
                      </a>
                    </dd>
                  </div>
                )}
                <div>
                  <dt>Pool ID</dt>
                  <dd>{engine?.poolId ?? "—"}</dd>
                </div>
                <div>
                  <dt>Tick / active liquidity</dt>
                  <dd>{state ? `${state.tick} / ${state.liquidity}` : "—"}</dd>
                </div>
                <div>
                  <dt>Claim accounting</dt>
                  <dd>
                    {state
                      ? state.fees.every((f) => f.claims === f.accrued)
                        ? "Hook claims equal unburned fees"
                        : "Accounting mismatch — inspect on explorer"
                      : "—"}
                  </dd>
                </div>
                <div>
                  <dt>RPC source</dt>
                  <dd>{engine?.lastRpc || "Connecting"}</dd>
                </div>
              </dl>
              <a href="./imd-deployment.json">View deployment manifest ↗</a>
            </div>
            <div>
              <h2>Wallet tools</h2>
              <p className="small muted-text">
                Transfer WHAL to another address, or remove your PoolSwapTest
                spending allowance.
              </p>
              <form
                onSubmit={(e) => {
                  e.preventDefault();
                  void run("Transferring WHAL", async () => {
                    if (!isAddress(recipient))
                      throw Error("Enter a valid recipient address.");
                    if (BigInt(recipient) === 0n)
                      throw Error("Choose a nonzero recipient.");
                    const value = amountOf(transferAmount, decimals);
                    await transact("WHAL transfer", () =>
                      engine!.send(
                        account!,
                        config!.token.address,
                        config!.token.abi,
                        "transfer",
                        [recipient, value],
                      ),
                    );
                  });
                }}
              >
                <label htmlFor="recipient">Recipient address</label>
                <input
                  id="recipient"
                  placeholder="0x…"
                  value={recipient}
                  disabled={!!busy}
                  onChange={(e) => setRecipient(e.target.value)}
                  autoComplete="off"
                />
                <label htmlFor="transfer-amount">WHAL to transfer</label>
                <input
                  id="transfer-amount"
                  inputMode="decimal"
                  value={transferAmount}
                  disabled={!!busy}
                  onChange={(e) => setTransferAmount(e.target.value)}
                />
                <button className="outline" disabled={!ready}>
                  Transfer WHAL
                </button>
              </form>
              <button
                className="outline next"
                disabled={!ready || !state?.allowance}
                onClick={() =>
                  run("Revoking allowance", () =>
                    transact("Allowance removal", () =>
                      engine!.approve(account!, 0n),
                    ),
                  )
                }
              >
                Revoke router allowance
              </button>
              <p className="small muted-text">
                Allowance: {display(state?.allowance, decimals)} WHAL
              </p>
              {d && (
                <a href={d.network.faucets[0]} target="_blank" rel="noreferrer">
                  Get Sepolia test ETH ↗
                </a>
              )}
            </div>
          </div>
        </details>
      </main>
      <footer>
        <span className="footer-brand">
          whale tax <span>Small moves. Lighter fees.</span>
        </span>
        <span>
          Sepolia experiment · Test assets have no intended monetary value
        </span>
        <a
          href={
            d?.integrations.poolSwapTestSource ??
            "https://developers.uniswap.org/docs/protocols/v4/deployments"
          }
          target="_blank"
          rel="noreferrer"
        >
          Uniswap deployments ↗
        </a>
      </footer>
    </>
  );
}
