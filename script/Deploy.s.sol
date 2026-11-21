// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {AgentBond} from "../src/AgentBond.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {MockIdentityRegistry} from "../src/MockIdentityRegistry.sol";
import {DeployConfig} from "./DeployConfig.sol";

interface IERC20Meta {
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

interface IERC165 {
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

/// @notice Deploys AgentBond on Ethereum mainnet (1), Base (8453) or local anvil (31337).
///         - Prints the chain it is on.
///         - Checks the chain's canonical USDC (symbol "USDC", 6 decimals) before doing anything.
///         - On live chains, checks the ERC-8004 Identity Registry has code (and ERC-721 if advertised).
///         - REFUSES to broadcast on chain 1 / 8453 unless env CONFIRM_MAINNET=yes.
///         - On a live broadcast, writes the AgentBond, USDC and registry addresses into web/src/deployments.json.
///         Dry run (no --broadcast) is always allowed and prints gas estimates.
contract Deploy is Script {
    string internal constant DEPLOYMENTS_PATH = "web/src/deployments.json";
    bytes4 internal constant ERC721_INTERFACE = 0x80ac58cd;

    function run() external returns (AgentBond agentBond, address usdc, address registry) {
        DeployConfig.Chain memory c = DeployConfig.get(block.chainid);
        console2.log("==> Chain:", c.name);
        console2.log("    chainId:", block.chainid);

        bool broadcasting =
            vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        if (c.isMainnet) {
            _checkUsdc(c.usdc);
            _checkRegistry(c.identityRegistry);
            if (broadcasting) {
                require(
                    keccak256(bytes(vm.envOr("CONFIRM_MAINNET", string("")))) == keccak256("yes"),
                    "Deploy: refusing to broadcast on a live chain without CONFIRM_MAINNET=yes"
                );
                console2.log("    CONFIRM_MAINNET=yes - LIVE BROADCAST");
            } else {
                console2.log("    dry run (no --broadcast): nothing will be sent");
            }
        }

        vm.startBroadcast();
        if (c.isMainnet) {
            usdc = c.usdc;
            registry = c.identityRegistry;
        } else {
            usdc = address(new MockUSDC());
            registry = address(new MockIdentityRegistry());
        }
        agentBond = new AgentBond(usdc, registry, DeployConfig.WITHDRAW_COOLDOWN, DeployConfig.CLAIM_TIMEOUT);
        vm.stopBroadcast();

        console2.log("AgentBond", address(agentBond));
        console2.log("USDC", usdc);
        console2.log("IdentityRegistry", registry);
        console2.log("withdrawCooldown", DeployConfig.WITHDRAW_COOLDOWN);
        console2.log("claimTimeout", DeployConfig.CLAIM_TIMEOUT);

        if (broadcasting) {
            _writeWebConfig(address(agentBond), usdc, registry);
        }
    }

    function _checkUsdc(address token) internal view {
        require(token.code.length > 0, "Deploy: USDC has no code on this chain");
        require(keccak256(bytes(IERC20Meta(token).symbol())) == keccak256("USDC"), "Deploy: USDC symbol mismatch");
        require(IERC20Meta(token).decimals() == 6, "Deploy: USDC decimals mismatch");
        console2.log("    USDC verified (symbol USDC, 6 decimals):", token);
    }

    function _checkRegistry(address registry) internal view {
        require(registry.code.length > 0, "Deploy: ERC-8004 identity registry has no code");
        console2.log("    Identity Registry has code:", registry);
        (bool ok, bytes memory data) =
            registry.staticcall(abi.encodeWithSelector(IERC165.supportsInterface.selector, ERC721_INTERFACE));
        if (ok && data.length >= 32 && abi.decode(data, (bool))) {
            console2.log("    Identity Registry supports ERC-721");
        } else {
            console2.log("    Identity Registry did not advertise ERC-721 (continuing; ownerOf is checked in tests)");
        }
    }

    /// @dev Updates only this chain's entry in web/src/deployments.json. No-op if the file is missing.
    function _writeWebConfig(address agentBond, address usdc, address registry) internal {
        string memory path = vm.envOr("DEPLOYMENTS_PATH", DEPLOYMENTS_PATH);
        if (!vm.exists(path)) {
            console2.log("    skip writing dapp config: file not found:", path);
            return;
        }
        string memory key = string.concat(".", vm.toString(block.chainid));
        string memory obj = "dep";
        vm.serializeAddress(obj, "agentBond", agentBond);
        vm.serializeAddress(obj, "usdc", usdc);
        string memory json = vm.serializeAddress(obj, "registry", registry);
        vm.writeJson(json, path, key);
        console2.log("    wrote AgentBond + USDC + registry to", path);
    }
}
