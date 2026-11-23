// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AgentBond} from "../../src/AgentBond.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {DeployConfig} from "../../script/DeployConfig.sol";

/// @dev Runs the production Deploy script against a live-chain fork (no broadcast to a real network).
abstract contract DeployForkBase is Test {
    bool active;

    function _rpcEnv() internal pure virtual returns (string memory);
    function _chainId() internal pure virtual returns (uint256);

    function setUp() public {
        if (block.chainid == _chainId()) {
            // already on this chain's fork (forge test --fork-url ...)
        } else if (block.chainid == 31337) {
            string memory rpc = vm.envOr(_rpcEnv(), string(""));
            if (bytes(rpc).length == 0) return;
            vm.createSelectFork(rpc);
        } else {
            return;
        }
        active = true;
        assertEq(block.chainid, _chainId(), "wrong fork chain");
    }

    modifier onFork() {
        if (!active) {
            vm.skip(true);
            return;
        }
        _;
    }

    function test_fork_deployScript_bondCanonicalUsdcAndRegistry() public onFork {
        Deploy script = new Deploy();
        (AgentBond agentBond, address usdc, address registry) = script.run();

        assertTrue(address(agentBond).code.length > 0, "AgentBond not deployed");
        DeployConfig.Chain memory c = DeployConfig.get(block.chainid);
        assertEq(usdc, c.usdc, "must use canonical USDC");
        assertEq(registry, c.identityRegistry, "must use ERC-8004 registry");
        assertEq(IERC20Metadata(usdc).symbol(), "USDC");
        assertEq(IERC20Metadata(usdc).decimals(), 6);
        assertGt(registry.code.length, 0, "registry must have code");
        assertEq(address(agentBond.usdc()), usdc);
        assertEq(agentBond.identityRegistry(), registry);
        assertEq(agentBond.withdrawCooldown(), DeployConfig.WITHDRAW_COOLDOWN);
        assertEq(agentBond.claimTimeout(), DeployConfig.CLAIM_TIMEOUT);
        assertEq(agentBond.claimDeposit(), DeployConfig.CLAIM_DEPOSIT);
    }

    function test_fork_deployScript_confirmMainnetNotSetIsDryRunSafe() public onFork {
        // In a test, ForgeContext is not ScriptBroadcast, so run() must still succeed
        // without CONFIRM_MAINNET (same path as a CLI dry-run).
        vm.setEnv("CONFIRM_MAINNET", "");
        Deploy script = new Deploy();
        (AgentBond agentBond,,) = script.run();
        assertTrue(address(agentBond).code.length > 0);
    }
}

contract EthereumDeployForkTest is DeployForkBase {
    function _rpcEnv() internal pure override returns (string memory) {
        return "MAINNET_FORK_RPC";
    }

    function _chainId() internal pure override returns (uint256) {
        return 1;
    }
}

contract BaseDeployForkTest is DeployForkBase {
    function _rpcEnv() internal pure override returns (string memory) {
        return "BASE_FORK_RPC";
    }

    function _chainId() internal pure override returns (uint256) {
        return 8453;
    }
}
