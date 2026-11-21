# Agentbond — spec (prototype, 22 Nov 2026)

Source: overnight agent-payments research, idea 3. Closest rivals: Bound (Stellar testnet), Armalo credibility bonds (Base, API-gated), Olas staking (emissions, not cover). ERC-8004 ships identity, not money.

**Problem.** Counterparties can look up an ERC-8004 agent but have no on-chain number that pays them if the agent misbehaves.

**Users.** Operators who want visible USDC coverage, and anyone who wants a public lookup and a way to file a claim.

**Scope (v0, Ethereum mainnet and Base, after an audit and Lef's OK).** One `AgentBond` contract. Bonds are keyed to an ERC-8004 agent id on the live Identity Registry (`0x8004A169FB4a3325136EB29fA0ceB6D2e539a432`), or to a plain address if there is no id. Anyone may post or top up USDC. The current 8004 owner (or agent wallet), or the address itself, names and rotates the arbiter and withdraws after a cooldown. Claimants file a claim with an evidence URI. The arbiter slashes up to the requested amount and the remaining bond, paid to the claimant (slash 0 rejects). Open claims block withdraw request and finalize. Claims expire after a timeout so a silent arbiter cannot freeze funds. Public `coverageOf` and slash history, plus a simple explorer and bond dapp. Out: mutual insurance, fees, other tokens or chains, a new identity registry.

**Choices (for Lef to review).**
1. 7-day withdraw cooldown and 14-day claim timeout, both immutable at deploy.
2. No protocol fee, no admin, no global pause.
3. Claims are required; no direct arbiter slash without a filed claim.
4. Anyone may top up; only the controller rotates the arbiter or withdraws. Arbiter rotation is blocked while claims are open.
5. A pending withdraw is not cancelled by a claim, but finalize is blocked, and a slash can reduce what is paid.
6. Working name “Agentbond”. Audit before any live deploy.

**Open questions.** Fees, a later Kleros-style arbiter, and whether a MutualPool should top up slashes.
