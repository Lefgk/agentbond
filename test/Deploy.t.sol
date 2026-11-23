// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {DeployConfig} from "../script/DeployConfig.sol";
import {AgentBond} from "../src/AgentBond.sol";

contract DeployConfigTest is Test {
    function test_ethereumAndBaseUsdcRegistryAndFlags() public pure {
        DeployConfig.Chain memory e = DeployConfig.get(1);
        assertEq(e.usdc, 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
        assertEq(e.identityRegistry, 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432);
        assertTrue(e.isMainnet);
        DeployConfig.Chain memory b = DeployConfig.get(8453);
        assertEq(b.usdc, 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
        assertEq(b.identityRegistry, 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432);
        assertTrue(b.isMainnet);
        assertEq(DeployConfig.WITHDRAW_COOLDOWN, 7 days);
        assertEq(DeployConfig.CLAIM_TIMEOUT, 14 days);
        assertEq(DeployConfig.CLAIM_DEPOSIT, 1e6);
    }

    function test_anvilConfigIsNotMainnet() public pure {
        DeployConfig.Chain memory c = DeployConfig.get(31337);
        assertEq(c.usdc, address(0));
        assertEq(c.identityRegistry, address(0));
        assertFalse(c.isMainnet);
    }

    function test_unsupportedChainReverts() public {
        vm.chainId(11155111); // Sepolia is not a supported target
        Deploy script = new Deploy();
        vm.expectRevert(bytes("DeployConfig: unsupported chain (only 1, 8453, 31337)"));
        script.run();
    }

    function test_deployScriptOnAnvilDeploysBondMockUsdcAndRegistry() public {
        if (block.chainid != 31337) {
            vm.skip(true);
            return;
        }
        Deploy script = new Deploy();
        (AgentBond agentBond, address usdc, address registry) = script.run();
        assertTrue(address(agentBond).code.length > 0);
        assertTrue(usdc.code.length > 0);
        assertTrue(registry.code.length > 0);
        assertEq(address(agentBond.usdc()), usdc);
        assertEq(agentBond.identityRegistry(), registry);
        assertEq(agentBond.withdrawCooldown(), 7 days);
        assertEq(agentBond.claimTimeout(), 14 days);
    }
}
