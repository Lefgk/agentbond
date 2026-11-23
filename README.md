# Agentbond

A public USDC surety bond for AI agents on Ethereum. An operator posts coverage against an **ERC-8004 agent id** (or a plain address), names an **arbiter**, and anyone can look the number up. Claimants file a claim with an evidence URI; the arbiter may **slash** up to the remaining bond to the claimant. Withdrawals have a **cooldown** and are blocked while claims are open.

> Prototype, **not audited**. It targets **Ethereum mainnet (1)** and **Base (8453)**, plus local anvil (31337) for development. The deploy scripts refuse any other chain and **refuse to broadcast on 1/8453 unless `CONFIRM_MAINNET=yes`**. Nothing has been deployed.

See [SPEC.md](SPEC.md) for the problem, competitors and choices, and [DEPLOY.md](DEPLOY.md) for the full deploy runbook.

## Layout
| Path | What |
|---|---|
| `src/AgentBond.sol` | Bonds, claims, slashing, cooldown withdraw, public coverage and slash history |
| `src/MockUSDC.sol`, `src/MockIdentityRegistry.sol` | Local-only mocks. Never deploy to mainnet |
| `src/interfaces/IIdentityRegistry.sol` | Minimal ERC-8004 surface (`ownerOf`, `tokenURI`, `getAgentWallet`) |
| `test/` | Unit, fuzz and invariant tests (Foundry) |
| `test/fork/` | Fork tests against real Circle USDC and the live ERC-8004 registry, plus a fork test of `Deploy.s.sol` |
| `script/Deploy.s.sol`, `script/DeployConfig.sol` | Deploy script and per-chain config |
| `script/deploy.sh`, `script/verify.sh`, `script/deploy-anvil.sh` | Dry-run/broadcast wrapper, Etherscan v2 verify, local deploy |
| `script/dry-run-fork.sh`, `script/test-deploy-fork.sh` | Anvil-fork dry run (port 8628) and deploy-script tests |
| `web/` | Vite + React + wagmi/viem explorer and bond page |

## How it works
1. **Deposit.** `depositForAgent(agentId, arbiter, amount)` or `depositForAccount(account, arbiter, amount)`. Only the controller (8004 owner/agent wallet, or the account itself) can make the first deposit, which names the arbiter; anyone may top up after that. The 8004 owner (not the agent wallet) changes the arbiter with `setArbiter` (queues it) and `applyArbiter` after 7 days with no open claims.
2. **Look up.** `coverageOfAgent` / `coverageOfAccount` returns remaining coverage, arbiter, operator, open claims and totals. `slashHistory*` returns every slash.
3. **Claim.** A non-controller files `fileClaim` with an evidence URI and escrows a 1 USDC claim deposit (refunded on a slash or expiry; added to the bond on a rejection or cancel). The arbiter calls `resolveClaim(id, slashAmount, reasonHash)` — `0` rejects, anything else pays the claimant and cannot exceed the request or the remaining bond.
4. **Withdraw.** The 8004 owner (or agent wallet) / the account calls `requestWithdraw`, waits 7 days, then `withdraw`. Open claims block both the request and the finalize. A claim can be cancelled by the claimant or expired by anyone after 14 days.

## Develop

```bash
forge test
make test-dapp
# Fork tests and a deploy dry run (anvil port 8628 only):
make dry-run-mainnet
make test-fork-deploy
```

## Needs Lef's decision
1. **Audit before any live deploy.** Recommended: the contract holds real USDC.
2. **Live deploy go-ahead and key.** Then: `CONFIRM_MAINNET=yes make deploy-mainnet` (and `make deploy-base`).
3. **Etherscan v2 API key** to verify.
4. **Chain order.** Base first (cheap, and where many agents already live) is the recommendation.
5. The choices listed in [SPEC.md](SPEC.md) (cooldown, claim timeout, no fees, claim-gated slash, name).

## Known limits
- The arbiter is trusted. A bad arbiter can slash; a silent one only delays withdraw until the 14-day claim timeout.
- If an 8004 agent NFT is burned, nobody can withdraw that bond.
- Fee-on-transfer tokens are unsupported. USDC is fine.
- USDC blocklisting: if Circle blocks the contract or a recipient, those transfers revert.
- The web app reads claim and slash data from the contract, not from an indexer.

## Contact

Support and questions: [lg.playstudio@gmail.com](mailto:lg.playstudio@gmail.com)
