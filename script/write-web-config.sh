#!/usr/bin/env bash
# Update web/src/deployments.json for one chain. No secrets.
# Usage: write-web-config.sh <chainId> <agentBondAddress> [usdcAddress] [registryAddress]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILE="${DEPLOYMENTS_PATH:-$ROOT/web/src/deployments.json}"
CHAIN_ID=${1:?chain id}
AGENTBOND=${2:?agentbond address}
USDC=${3:-}
REGISTRY=${4:-}
if [ ! -f "$FILE" ]; then
  echo "write-web-config: $FILE not found" >&2
  exit 1
fi
tmp="$(mktemp)"
if [ -n "$USDC" ] && [ -n "$REGISTRY" ]; then
  jq --arg c "$CHAIN_ID" --arg b "$AGENTBOND" --arg u "$USDC" --arg r "$REGISTRY" \
    '.[$c] = ((.[$c] // {}) | .agentBond = $b | .usdc = $u | .registry = $r)' "$FILE" > "$tmp"
elif [ -n "$USDC" ]; then
  jq --arg c "$CHAIN_ID" --arg b "$AGENTBOND" --arg u "$USDC" \
    '.[$c] = ((.[$c] // {}) | .agentBond = $b | .usdc = $u)' "$FILE" > "$tmp"
else
  jq --arg c "$CHAIN_ID" --arg b "$AGENTBOND" \
    '.[$c] = ((.[$c] // {}) | .agentBond = $b)' "$FILE" > "$tmp"
fi
mv "$tmp" "$FILE"
echo "Wrote AgentBond $AGENTBOND to web/src/deployments.json (chain $CHAIN_ID)"
