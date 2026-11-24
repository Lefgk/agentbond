import { http, createConfig } from "wagmi";
import { mainnet, base, foundry } from "wagmi/chains";
import { injected } from "wagmi/connectors";
import type { Address } from "viem";
import deploymentsFile from "./deployments.json";

const env = import.meta.env;

export const config = createConfig({
  chains: [base, mainnet, foundry],
  connectors: [injected()],
  transports: {
    [mainnet.id]: http(env.VITE_MAINNET_RPC || undefined),
    [base.id]: http(env.VITE_BASE_RPC || undefined),
    [foundry.id]: http(env.VITE_ANVIL_RPC || "http://127.0.0.1:8628"),
  },
});

const ZERO = "0x0000000000000000000000000000000000000000";
const asAddr = (v?: string) =>
  v && /^0x[0-9a-fA-F]{40}$/.test(v) && v.toLowerCase() !== ZERO ? (v as Address) : undefined;

type DeploymentRow = { agentBond?: string; usdc?: string; registry?: string };
const file = deploymentsFile as Record<string, DeploymentRow>;
const fromFile = (chainId: number): { agentBond?: Address; usdc?: Address; registry?: Address } => {
  const row = file[String(chainId)] ?? {};
  return { agentBond: asAddr(row.agentBond), usdc: asAddr(row.usdc), registry: asAddr(row.registry) };
};

/** Per-chain deployment addresses. Env vars override deployments.json. Empty agentBond = not deployed yet. */
export const deployments: Record<
  number,
  { agentBond?: Address; usdc?: Address; registry?: Address; live: boolean }
> = {
  [mainnet.id]: {
    agentBond: asAddr(env.VITE_AGENTBOND_MAINNET) ?? fromFile(mainnet.id).agentBond,
    usdc: fromFile(mainnet.id).usdc ?? "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
    registry: fromFile(mainnet.id).registry ?? "0x8004A169FB4a3325136EB29fA0ceB6D2e539a432",
    live: true,
  },
  [base.id]: {
    agentBond: asAddr(env.VITE_AGENTBOND_BASE) ?? fromFile(base.id).agentBond,
    usdc: fromFile(base.id).usdc ?? "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
    registry: fromFile(base.id).registry ?? "0x8004A169FB4a3325136EB29fA0ceB6D2e539a432",
    live: true,
  },
  // Anvil defaults match `script/deploy-anvil.sh` on a fresh anvil when the json entry is empty
  // (MockUSDC at nonce 0, MockIdentityRegistry at nonce 1, AgentBond at nonce 2).
  [foundry.id]: {
    agentBond:
      asAddr(env.VITE_AGENTBOND_ANVIL) ??
      fromFile(foundry.id).agentBond ??
      "0x9fE46736679d2D9a65F4f516149658435bF192Ea",
    usdc: asAddr(env.VITE_USDC_ANVIL) ?? fromFile(foundry.id).usdc ?? "0x5FbDB2315678afecb367f032d93F642f64180aa3",
    registry:
      asAddr(env.VITE_REGISTRY_ANVIL) ??
      fromFile(foundry.id).registry ??
      "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512",
    live: false,
  },
};

declare module "wagmi" {
  interface Register {
    config: typeof config;
  }
}
