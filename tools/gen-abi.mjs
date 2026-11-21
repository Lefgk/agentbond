#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import { writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const env = { ...process.env, PATH: `${process.env.HOME}/.foundry/bin:${process.env.PATH}` };
const abi = execFileSync("forge", ["inspect", "src/AgentBond.sol:AgentBond", "abi", "--json"], {
  cwd: root,
  env,
  encoding: "utf8",
});
const out = `// Generated from \`forge inspect src/AgentBond.sol:AgentBond abi --json\`.
export const agentBondAbi = ${abi.trim()} as const;

export const identityRegistryAbi = [
  {
    type: "function",
    name: "ownerOf",
    stateMutability: "view",
    inputs: [{ name: "agentId", type: "uint256" }],
    outputs: [{ name: "", type: "address" }],
  },
  {
    type: "function",
    name: "tokenURI",
    stateMutability: "view",
    inputs: [{ name: "agentId", type: "uint256" }],
    outputs: [{ name: "", type: "string" }],
  },
  {
    type: "function",
    name: "getAgentWallet",
    stateMutability: "view",
    inputs: [{ name: "agentId", type: "uint256" }],
    outputs: [{ name: "", type: "address" }],
  },
] as const;
`;
writeFileSync(join(root, "web/src/abi.ts"), out);
console.log("wrote web/src/abi.ts");
