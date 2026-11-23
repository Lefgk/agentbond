import { useMemo, useState } from "react";
import {
  useAccount,
  useChainId,
  useConnect,
  useDisconnect,
  usePublicClient,
  useReadContract,
  useSwitchChain,
  useWriteContract,
} from "wagmi";
import { erc20Abi, formatUnits, keccak256, parseUnits, stringToHex, type Address } from "viem";
import { agentBondAbi, identityRegistryAbi } from "./abi";
import { deployments } from "./config";

const short = (a?: string) => (a ? `${a.slice(0, 6)}…${a.slice(-4)}` : "");
const KIND = ["None", "Agent id", "Account"] as const;
const CLAIM_STATUS = ["None", "Pending", "Slashed", "Rejected", "Cancelled", "Expired"] as const;
const isAddress = (v: string) => /^0x[0-9a-fA-F]{40}$/.test(v);
const looksLikeId = (v: string) => /^\d+$/.test(v.trim());

export default function App() {
  const { address, isConnected } = useAccount();
  const chainId = useChainId();
  const { connect, connectors } = useConnect();
  const { disconnect } = useDisconnect();
  const { switchChain, chains } = useSwitchChain();
  const dep = deployments[chainId] ?? {};
  const [query, setQuery] = useState("");

  return (
    <div className="wrap">
      <h1>Agentbond</h1>
      <div className="muted">
        Public USDC surety bonds for ERC-8004 agents: post coverage, look it up, file a claim,
        slash to a claimant, withdraw after a cooldown. Prototype — not audited. Ethereum, Base
        and local anvil.
      </div>

      <div className="card">
        <h2>Wallet</h2>
        {!isConnected ? (
          <div className="row">
            {connectors.map((c) => (
              <button key={c.uid} onClick={() => connect({ connector: c })}>
                Connect {c.name}
              </button>
            ))}
          </div>
        ) : (
          <div className="row">
            <span>
              Connected <code>{address}</code>
            </span>
            <button className="ghost" onClick={() => disconnect()}>
              Disconnect
            </button>
          </div>
        )}
        <div className="row">
          {chains.map((c) => (
            <button
              key={c.id}
              className={c.id === chainId ? "" : "ghost"}
              onClick={() => switchChain({ chainId: c.id })}
            >
              {c.name}
            </button>
          ))}
        </div>
        {!deployments[chainId] && (
          <div className="warn">Unsupported chain: use Ethereum, Base or local anvil.</div>
        )}
        {deployments[chainId] && !dep.agentBond && (
          <div className="warn">
            <strong>Not deployed yet</strong> on this chain — the AgentBond address is empty. Core
            flows stay disabled until you deploy (<code>make deploy-mainnet</code> or{" "}
            <code>make deploy-base</code>), which writes the address into{" "}
            <code>web/src/deployments.json</code>. You can still use the explorer after a deploy.
          </div>
        )}
        {deployments[chainId]?.live && dep.agentBond && (
          <div className="warn">
            Live chain with real funds. This contract is NOT audited — only deposit amounts you can
            afford to lose.
          </div>
        )}
      </div>

      {dep.agentBond && dep.usdc && (
        <>
          <Explorer agentBond={dep.agentBond} registry={dep.registry} query={query} setQuery={setQuery} />
          {isConnected && address && (
            <BondPage
              agentBond={dep.agentBond}
              usdc={dep.usdc}
              query={query}
              setQuery={setQuery}
            />
          )}
        </>
      )}
    </div>
  );
}

function useTx() {
  const { writeContractAsync } = useWriteContract();
  const client = usePublicClient();
  const [status, setStatus] = useState("");
  const run = async (label: string, fn: () => Promise<`0x${string}`>) => {
    try {
      setStatus(`${label}: confirm in wallet…`);
      const hash = await fn();
      setStatus(`${label}: pending ${short(hash)}`);
      await client!.waitForTransactionReceipt({ hash });
      setStatus(`${label}: confirmed ✓`);
      return true;
    } catch (e) {
      setStatus(`${label}: ${(e as Error).message.split("\n")[0]}`);
      return false;
    }
  };
  return { writeContractAsync, status, run };
}

function useKey(agentBond: Address, query: string) {
  const trimmed = query.trim();
  const agentId = looksLikeId(trimmed) ? BigInt(trimmed) : undefined;
  const account = isAddress(trimmed) ? (trimmed as Address) : undefined;
  const { data: key } = useReadContract({
    address: agentBond,
    abi: agentBondAbi,
    functionName: agentId !== undefined ? "keyOfAgent" : "keyOfAccount",
    args: agentId !== undefined ? [agentId] : account ? [account] : undefined,
    query: { enabled: agentId !== undefined || !!account },
  });
  return { agentId, account, key: key as `0x${string}` | undefined, ready: agentId !== undefined || !!account };
}

function Explorer({
  agentBond,
  registry,
  query,
  setQuery,
}: {
  agentBond: Address;
  registry?: Address;
  query: string;
  setQuery: (v: string) => void;
}) {
  const { agentId, account, key, ready } = useKey(agentBond, query);
  const { data: coverage } = useReadContract({
    address: agentBond,
    abi: agentBondAbi,
    functionName: "coverageOf",
    args: key ? [key] : undefined,
    query: { enabled: !!key },
  });
  const { data: history } = useReadContract({
    address: agentBond,
    abi: agentBondAbi,
    functionName: "slashHistory",
    args: key ? [key] : undefined,
    query: { enabled: !!key },
  });
  const { data: claimIds } = useReadContract({
    address: agentBond,
    abi: agentBondAbi,
    functionName: "claimIds",
    args: key ? [key] : undefined,
    query: { enabled: !!key },
  });
  const { data: owner } = useReadContract({
    address: registry,
    abi: identityRegistryAbi,
    functionName: "ownerOf",
    args: agentId !== undefined ? [agentId] : undefined,
    query: { enabled: !!registry && agentId !== undefined },
  });
  const { data: tokenURI } = useReadContract({
    address: registry,
    abi: identityRegistryAbi,
    functionName: "tokenURI",
    args: agentId !== undefined ? [agentId] : undefined,
    query: { enabled: !!registry && agentId !== undefined },
  });
  const { data: wallet } = useReadContract({
    address: registry,
    abi: identityRegistryAbi,
    functionName: "getAgentWallet",
    args: agentId !== undefined ? [agentId] : undefined,
    query: { enabled: !!registry && agentId !== undefined },
  });

  const cov = coverage as
    | {
        kind: number;
        agentId: bigint;
        account: Address;
        arbiter: Address;
        operator: Address;
        amount: bigint;
        totalDeposited: bigint;
        totalSlashed: bigint;
        pendingWithdraw: bigint;
        withdrawAvailableAt: bigint;
        openClaims: number;
        slashCount: number;
      }
    | undefined;

  return (
    <div className="card">
      <h2>Explorer</h2>
      <div className="row">
        <label>
          Agent id or address
          <input
            value={query}
            placeholder="e.g. 22 or 0x…"
            onChange={(e) => setQuery(e.target.value)}
          />
        </label>
      </div>
      {ready && !cov && <div className="muted">Looking up…</div>}
      {cov && cov.arbiter === "0x0000000000000000000000000000000000000000" && (
        <div className="muted">No bond posted for this identity yet.</div>
      )}
      {cov && cov.arbiter !== "0x0000000000000000000000000000000000000000" && (
        <>
          <table>
            <tbody>
              <tr>
                <th>Kind</th>
                <td>{KIND[cov.kind] ?? cov.kind}</td>
              </tr>
              <tr>
                <th>Coverage</th>
                <td className="ok">{formatUnits(cov.amount, 6)} USDC</td>
              </tr>
              <tr>
                <th>Deposited / slashed</th>
                <td>
                  {formatUnits(cov.totalDeposited, 6)} / {formatUnits(cov.totalSlashed, 6)} USDC
                </td>
              </tr>
              <tr>
                <th>Arbiter</th>
                <td>
                  <code>{cov.arbiter}</code>
                </td>
              </tr>
              <tr>
                <th>Operator</th>
                <td>
                  <code>{cov.operator}</code>
                </td>
              </tr>
              <tr>
                <th>Open claims</th>
                <td>{cov.openClaims}</td>
              </tr>
              {cov.pendingWithdraw > 0n && (
                <tr>
                  <th>Pending withdraw</th>
                  <td>
                    {formatUnits(cov.pendingWithdraw, 6)} USDC at{" "}
                    {new Date(Number(cov.withdrawAvailableAt) * 1000).toLocaleString()}
                  </td>
                </tr>
              )}
              {agentId !== undefined && (
                <tr>
                  <th>8004 owner / wallet</th>
                  <td>
                    <code>{owner ? short(owner) : "—"}</code>
                    {wallet ? (
                      <>
                        {" "}
                        / <code>{short(wallet)}</code>
                      </>
                    ) : null}
                  </td>
                </tr>
              )}
              {tokenURI && (
                <tr>
                  <th>tokenURI</th>
                  <td>
                    <code>{tokenURI}</code>
                  </td>
                </tr>
              )}
            </tbody>
          </table>
          <h2>Slash history</h2>
          {!history || (history as unknown[]).length === 0 ? (
            <div className="muted">No slashes.</div>
          ) : (
            <table>
              <thead>
                <tr>
                  <th>Claim</th>
                  <th>Claimant</th>
                  <th>Amount</th>
                  <th>When</th>
                </tr>
              </thead>
              <tbody>
                {(
                  history as {
                    claimId: bigint;
                    claimant: Address;
                    amount: bigint;
                    reasonHash: `0x${string}`;
                    timestamp: bigint;
                  }[]
                ).map((s) => (
                  <tr key={s.claimId.toString()}>
                    <td>#{s.claimId.toString()}</td>
                    <td>
                      <code>{short(s.claimant)}</code>
                    </td>
                    <td>{formatUnits(s.amount, 6)} USDC</td>
                    <td>{new Date(Number(s.timestamp) * 1000).toLocaleString()}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
          {claimIds && (claimIds as bigint[]).length > 0 && (
            <div className="muted">Claim ids: {(claimIds as bigint[]).map((i) => i.toString()).join(", ")}</div>
          )}
        </>
      )}
      {account && <div className="muted">Address key for {short(account)}</div>}
    </div>
  );
}

function BondPage({
  agentBond,
  usdc,
  query,
  setQuery,
}: {
  agentBond: Address;
  usdc: Address;
  query: string;
  setQuery: (v: string) => void;
}) {
  const { writeContractAsync, status, run } = useTx();
  const { key, agentId, account, ready } = useKey(agentBond, query);
  const [amount, setAmount] = useState("100");
  const [arbiter, setArbiter] = useState("");
  const [evidence, setEvidence] = useState("ipfs://");
  const [claimAmt, setClaimAmt] = useState("10");
  const [claimId, setClaimId] = useState("");
  const [slashAmt, setSlashAmt] = useState("0");
  const [reason, setReason] = useState("");
  const [withdrawAmt, setWithdrawAmt] = useState("");
  const { data: claimDeposit } = useReadContract({
    address: agentBond,
    abi: agentBondAbi,
    functionName: "claimDeposit",
  });

  const fileClaim = async () => {
    const dep = (claimDeposit as bigint | undefined) ?? 0n;
    if (
      dep > 0n &&
      !(await run(`Approve ${formatUnits(dep, 6)} USDC claim deposit`, () =>
        writeContractAsync({ address: usdc, abi: erc20Abi, functionName: "approve", args: [agentBond, dep] }),
      ))
    )
      return;
    await run("File claim", () =>
      writeContractAsync({
        address: agentBond,
        abi: agentBondAbi,
        functionName: "fileClaim",
        args: [key!, parseUnits(claimAmt, 6), evidence],
      }),
    );
  };

  const identArgs = useMemo(() => {
    if (agentId !== undefined) return { mode: "agent" as const, id: agentId };
    if (account) return { mode: "account" as const, account };
    return undefined;
  }, [agentId, account]);

  const deposit = async () => {
    if (!identArgs) return;
    const amt = parseUnits(amount, 6);
    const arb = (arbiter || "0x0000000000000000000000000000000000000000") as Address;
    if (
      await run("Approve USDC", () =>
        writeContractAsync({ address: usdc, abi: erc20Abi, functionName: "approve", args: [agentBond, amt] }),
      )
    ) {
      await run("Deposit bond", () =>
        writeContractAsync({
          address: agentBond,
          abi: agentBondAbi,
          functionName: identArgs.mode === "agent" ? "depositForAgent" : "depositForAccount",
          args:
            identArgs.mode === "agent" ? [identArgs.id, arb, amt] : [identArgs.account, arb, amt],
        }),
      );
    }
  };

  return (
    <div className="card">
      <h2>Bond</h2>
      <div className="muted">
        Uses the identity in the explorer box above. Only the agent's owner (or the account itself)
        can create a bond and name its arbiter; anyone may top up. Arbiter changes wait 7 days.
        Filing a claim escrows a small USDC deposit: refunded on a slash or expiry, added to the bond
        if the claim is rejected or cancelled.
      </div>
      <div className="row">
        <label>
          Agent id or address
          <input value={query} placeholder="e.g. 22 or 0x…" onChange={(e) => setQuery(e.target.value)} />
        </label>
        <label>
          Amount (USDC)
          <input value={amount} onChange={(e) => setAmount(e.target.value)} />
        </label>
        <label>
          Arbiter (required on first deposit)
          <input value={arbiter} placeholder="0x…" onChange={(e) => setArbiter(e.target.value)} />
        </label>
        <button disabled={!ready} onClick={deposit}>
          Approve + deposit
        </button>
      </div>
      <div className="row">
        <button
          className="ghost"
          disabled={!key || !arbiter}
          onClick={() =>
            run("Queue arbiter change", () =>
              writeContractAsync({
                address: agentBond,
                abi: agentBondAbi,
                functionName: "setArbiter",
                args: [key!, arbiter as Address],
              }),
            )
          }
        >
          Queue arbiter change
        </button>
        <button
          className="ghost"
          disabled={!key}
          onClick={() =>
            run("Apply arbiter", () =>
              writeContractAsync({
                address: agentBond,
                abi: agentBondAbi,
                functionName: "applyArbiter",
                args: [key!],
              }),
            )
          }
        >
          Apply arbiter (after 7 days)
        </button>
        <label>
          Withdraw amount (USDC)
          <input value={withdrawAmt} placeholder="amount" onChange={(e) => setWithdrawAmt(e.target.value)} />
        </label>
        <button
          className="ghost"
          disabled={!key || !withdrawAmt}
          onClick={() =>
            run("Request withdraw", () =>
              writeContractAsync({
                address: agentBond,
                abi: agentBondAbi,
                functionName: "requestWithdraw",
                args: [key!, parseUnits(withdrawAmt, 6)],
              }),
            )
          }
        >
          Request withdraw
        </button>
        <button
          className="ghost"
          disabled={!key}
          onClick={() =>
            run("Cancel withdraw", () =>
              writeContractAsync({
                address: agentBond,
                abi: agentBondAbi,
                functionName: "cancelWithdraw",
                args: [key!],
              }),
            )
          }
        >
          Cancel
        </button>
        <button
          disabled={!key}
          onClick={() =>
            run("Withdraw", () =>
              writeContractAsync({
                address: agentBond,
                abi: agentBondAbi,
                functionName: "withdraw",
                args: [key!],
              }),
            )
          }
        >
          Finalize withdraw
        </button>
      </div>

      <h2>Claims</h2>
      <div className="row">
        <label>
          Claim amount (USDC)
          <input value={claimAmt} onChange={(e) => setClaimAmt(e.target.value)} />
        </label>
        <label>
          Evidence URI
          <input value={evidence} onChange={(e) => setEvidence(e.target.value)} />
        </label>
        <button
          disabled={!key}
          onClick={fileClaim}
        >
          Approve deposit + file claim
        </button>
      </div>
      <div className="row">
        <label>
          Claim id
          <input value={claimId} placeholder="#" onChange={(e) => setClaimId(e.target.value)} />
        </label>
        <label>
          Slash amount (0 = reject)
          <input value={slashAmt} onChange={(e) => setSlashAmt(e.target.value)} />
        </label>
        <label>
          Reason hash (optional text)
          <input value={reason} placeholder="reason" onChange={(e) => setReason(e.target.value)} />
        </label>
        <button
          className="danger"
          disabled={!claimId}
          onClick={() =>
            run("Resolve / slash", () =>
              writeContractAsync({
                address: agentBond,
                abi: agentBondAbi,
                functionName: "resolveClaim",
                args: [
                  BigInt(claimId),
                  parseUnits(slashAmt || "0", 6),
                  keccak256(stringToHex(reason || "resolved")),
                ],
              }),
            )
          }
        >
          Arbiter: resolve
        </button>
        <button
          className="ghost"
          disabled={!claimId}
          onClick={() =>
            run("Cancel claim", () =>
              writeContractAsync({
                address: agentBond,
                abi: agentBondAbi,
                functionName: "cancelClaim",
                args: [BigInt(claimId)],
              }),
            )
          }
        >
          Cancel claim
        </button>
        <button
          className="ghost"
          disabled={!claimId}
          onClick={() =>
            run("Expire claim", () =>
              writeContractAsync({
                address: agentBond,
                abi: agentBondAbi,
                functionName: "expireClaim",
                args: [BigInt(claimId)],
              }),
            )
          }
        >
          Expire claim
        </button>
      </div>
      <div className="muted">{status}</div>
    </div>
  );
}
