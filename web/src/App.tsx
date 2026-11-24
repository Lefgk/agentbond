import { useMemo, useState } from "react";
import { useAccount, useChainId, useReadContract } from "wagmi";
import { erc20Abi, formatUnits, keccak256, parseUnits, stringToHex, type Address } from "viem";
import { agentBondAbi, identityRegistryAbi } from "./abi";
import { deployments } from "./config";
import { Addr, Empty, Hint, Loading, Shell, short, useTx } from "./ui";

const KIND = ["None", "Agent id", "Account"] as const;
const CLAIM_STATUS = ["None", "Pending", "Slashed", "Rejected", "Cancelled", "Expired"] as const;
const ZERO = "0x0000000000000000000000000000000000000000";
const isAddress = (v: string) => /^0x[0-9a-fA-F]{40}$/.test(v);
const looksLikeId = (v: string) => /^\d+$/.test(v.trim());

export default function App() {
  const { address, isConnected } = useAccount();
  const chainId = useChainId();
  const dep = deployments[chainId] ?? {};
  const [query, setQuery] = useState("");

  return (
    <Shell
      title="Agentbond"
      tagline="Public USDC surety bonds for AI agents. An agent's owner locks USDC as a bond; anyone can look up how much coverage an agent has, file a claim against it, and a named arbiter can pay a claimant out of the bond."
      steps={[
        "Look up an agent by ERC-8004 id or address: coverage and slash history are public.",
        "Owner posts a USDC bond and names an arbiter.",
        "Anyone harmed files a claim; the arbiter rejects it or slashes the bond to the claimant.",
        "Owner can withdraw unused bond after a cooldown.",
      ]}
      contractLabel="AgentBond"
      contractOf={(id) => deployments[id]?.agentBond}
      refs={[
        { label: "USDC", address: dep.usdc },
        { label: "ERC-8004 registry", address: dep.registry },
      ]}
      risk={
        <>
          <strong>Real funds.</strong> This contract is not audited. A posted bond can be paid out to claimants by the
          arbiter you name, so only bond amounts you can afford to lose and only name an arbiter you trust.
        </>
      }
    >
      {dep.agentBond && dep.usdc && (
        <>
          <Explorer agentBond={dep.agentBond} registry={dep.registry} query={query} setQuery={setQuery} />
          {isConnected && address ? (
            <BondPage agentBond={dep.agentBond} usdc={dep.usdc} query={query} setQuery={setQuery} />
          ) : (
            <Empty>Looking up a bond needs no wallet. Connect one to post a bond, file a claim or resolve one.</Empty>
          )}
        </>
      )}
    </Shell>
  );
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
      <h2>1. Look up a bond</h2>
      <p className="muted">Read-only. Enter an ERC-8004 agent id (a number) or an account address.</p>
      <div className="row">
        <label>
          Agent id or address
          <input
            value={query}
            placeholder="e.g. 22 or 0x…"
            spellCheck={false}
            onChange={(e) => setQuery(e.target.value.trim())}
          />
        </label>
      </div>
      {!query && <Empty>Enter an agent id or address to see its bond.</Empty>}
      {query && !ready && (
        <div className="bad muted">Enter a whole number (agent id) or a full address (0x followed by 40 hex characters).</div>
      )}
      {ready && !cov && <Loading>Looking up bond…</Loading>}
      {cov && cov.arbiter === ZERO && (
        <Empty>
          No bond posted for {agentId !== undefined ? `agent #${agentId.toString()}` : short(account)} on this network yet.
        </Empty>
      )}
      {cov && cov.arbiter !== ZERO && (
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
                  <Addr value={cov.arbiter} />
                </td>
              </tr>
              <tr>
                <th>Operator</th>
                <td>
                  <Addr value={cov.operator} />
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
                    <Addr value={owner} />
                    {wallet ? (
                      <>
                        {" "}
                        / <Addr value={wallet} />
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
          <h3>Slash history</h3>
          {!history || (history as unknown[]).length === 0 ? (
            <Empty>No slashes: this bond has never paid out a claim.</Empty>
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
                      <Addr value={s.claimant} />
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
  const { writeContractAsync, status, run, safe, fail } = useTx();
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
    const claimAmount = parseUnits(claimAmt, 6);
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
        args: [key!, claimAmount, evidence],
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
    if (arbiter && !isAddress(arbiter)) return fail("Arbiter must be a valid address (0x followed by 40 hex characters).");
    const amt = parseUnits(amount, 6);
    if (amt === 0n) return fail("Amount must be greater than 0.");
    const arb = (arbiter || ZERO) as Address;
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

  const tx = (label: string, functionName: "applyArbiter" | "cancelWithdraw" | "withdraw") => () =>
    run(label, () => writeContractAsync({ address: agentBond, abi: agentBondAbi, functionName, args: [key!] }));
  const claimTx = (label: string, functionName: "cancelClaim" | "expireClaim") => () =>
    run(label, () => writeContractAsync({ address: agentBond, abi: agentBondAbi, functionName, args: [BigInt(claimId)] }));
  const claimDep = (claimDeposit as bigint | undefined) ?? 0n;

  return (
    <div className="card">
      <h2>2. Manage a bond</h2>
      <p className="muted">
        Acts on the identity looked up above
        {agentId !== undefined ? ` (agent #${agentId.toString()})` : account ? ` (${short(account)})` : ""}. Only the
        agent's owner, or the account itself, can create a bond and name its arbiter. Anyone may top up.
      </p>
      {!ready && <Empty>Enter an agent id or address in step 1 first. The buttons below stay disabled until then.</Empty>}

      <h3>Post or top up (owner)</h3>
      <div className="row">
        <label>
          Agent id or address
          <input value={query} placeholder="e.g. 22 or 0x…" spellCheck={false} onChange={(e) => setQuery(e.target.value.trim())} />
        </label>
        <label>
          Amount (USDC)
          <input value={amount} inputMode="decimal" onChange={(e) => setAmount(e.target.value)} />
        </label>
        <label>
          Arbiter (required on first deposit)
          <input value={arbiter} placeholder="0x…" spellCheck={false} onChange={(e) => setArbiter(e.target.value.trim())} />
        </label>
        <button disabled={!ready} onClick={safe(deposit)}>
          Approve + deposit
        </button>
      </div>
      <Hint>
        Two wallet prompts: an approval for exactly this amount, then the deposit, which moves the USDC from your
        wallet into the AgentBond contract as public coverage. The arbiter can pay claimants out of it. Getting it
        back takes a withdraw request plus a cooldown.
      </Hint>

      <h3>Arbiter (owner)</h3>
      <div className="row">
        <button
          className="ghost"
          disabled={!key || !isAddress(arbiter)}
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
        <button className="ghost" disabled={!key} onClick={tx("Apply arbiter", "applyArbiter")}>
          Apply arbiter (after 7 days)
        </button>
      </div>
      <Hint>
        Queue proposes the address in the Arbiter field above as the new arbiter. Nothing changes for 7 days, then
        “Apply” makes it effective. No funds move.
      </Hint>

      <h3>Withdraw (owner)</h3>
      <div className="row">
        <label>
          Withdraw amount (USDC)
          <input value={withdrawAmt} placeholder="amount" inputMode="decimal" onChange={(e) => setWithdrawAmt(e.target.value)} />
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
        <button className="ghost" disabled={!key} onClick={tx("Cancel withdraw", "cancelWithdraw")}>
          Cancel request
        </button>
        <button disabled={!key} onClick={tx("Withdraw", "withdraw")}>
          Finalize withdraw
        </button>
      </div>
      <Hint>
        Request starts the cooldown for that amount; it stays slashable until you finalize. Finalize sends the USDC
        back once the cooldown has passed (the date shows in step 1 as “Pending withdraw”). Cancel keeps the bond in
        place. Requests and withdrawals are blocked while a claim is open.
      </Hint>

      <h3>File a claim (anyone)</h3>
      <div className="row">
        <label>
          Claim amount (USDC)
          <input value={claimAmt} inputMode="decimal" onChange={(e) => setClaimAmt(e.target.value)} />
        </label>
        <label>
          Evidence URI
          <input value={evidence} spellCheck={false} onChange={(e) => setEvidence(e.target.value)} />
        </label>
        <button disabled={!key} onClick={safe(fileClaim)}>
          {claimDep > 0n ? "Approve deposit + file claim" : "File claim"}
        </button>
      </div>
      <Hint>
        Files a public claim against this bond for the arbiter to decide.
        {claimDep > 0n
          ? ` It escrows a ${formatUnits(claimDep, 6)} USDC claim deposit from your wallet (approval, then the claim): refunded if the claim is slashed or expires, added to the bond if it is rejected or you cancel it.`
          : " One transaction; no deposit is required."}
      </Hint>

      <h3>Resolve a claim</h3>
      <div className="row">
        <label>
          Claim id
          <input value={claimId} placeholder="#" inputMode="numeric" onChange={(e) => setClaimId(e.target.value.trim())} />
        </label>
        <label>
          Slash amount (USDC, 0 = reject)
          <input value={slashAmt} inputMode="decimal" onChange={(e) => setSlashAmt(e.target.value)} />
        </label>
        <label>
          Reason (text, stored as a hash)
          <input value={reason} placeholder="reason" onChange={(e) => setReason(e.target.value)} />
        </label>
        <button
          className="danger"
          disabled={!claimId}
          onClick={() =>
            run("Resolve claim", () =>
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
        <button className="ghost" disabled={!claimId} onClick={claimTx("Cancel claim", "cancelClaim")}>
          Cancel claim
        </button>
        <button className="ghost" disabled={!claimId} onClick={claimTx("Expire claim", "expireClaim")}>
          Expire claim
        </button>
      </div>
      <Hint tone="danger">
        Resolve is for the bond's arbiter only and is final: a slash amount above 0 pays that much USDC from the bond
        to the claimant; 0 rejects the claim. Cancel is for the claimant. Expire closes a claim the arbiter never
        decided.
      </Hint>
      {status}
    </div>
  );
}
