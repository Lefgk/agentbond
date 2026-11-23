// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AgentBond} from "../../src/AgentBond.sol";
import {MockUSDC} from "../../src/MockUSDC.sol";
import {MockIdentityRegistry} from "../../src/MockIdentityRegistry.sol";

/// Audit 2026-11-23 regression tests. Each started life as a PoC that PASSED on main (exploit worked)
/// and now asserts the exploit is blocked. See AUDIT-2026-11-23.md.
contract AgentBondAuditRegression is Test {
    AgentBond bond;
    MockUSDC usdc;
    MockIdentityRegistry registry;
    address operator = makeAddr("operator");
    address arbiter = makeAddr("arbiter");
    address puppet = makeAddr("puppet");
    address alt = makeAddr("alt");
    address attacker = makeAddr("attacker");
    uint256 agentId;
    uint256 constant DEP = 1e6;

    function setUp() public {
        usdc = new MockUSDC();
        registry = new MockIdentityRegistry();
        bond = new AgentBond(address(usdc), address(registry), 7 days, 14 days, DEP);
        agentId = registry.register(operator, "ipfs://a");
        usdc.mint(operator, 1_000e6);
        usdc.mint(attacker, 10e6);
        usdc.mint(alt, 10e6);
        vm.prank(operator);
        usdc.approve(address(bond), type(uint256).max);
        vm.prank(attacker);
        usdc.approve(address(bond), type(uint256).max);
        vm.prank(alt);
        usdc.approve(address(bond), type(uint256).max);
    }

    // M-1: setArbiter was instant -> operator drained the bond in one block through a puppet arbiter.
    function test_M1_arbiterSwapNoLongerBypassesCooldown() public {
        vm.prank(operator);
        bond.depositForAgent(agentId, arbiter, 1_000e6);
        bytes32 key = bond.keyOfAgent(agentId);
        vm.prank(operator);
        bond.setArbiter(key, puppet);
        assertEq(bond.coverageOf(key).arbiter, arbiter, "not applied yet");
        vm.prank(operator);
        vm.expectRevert(AgentBond.ArbiterCooldownActive.selector);
        bond.applyArbiter(key);
        // puppet has no power yet
        vm.prank(alt);
        uint256 id = bond.fileClaim(key, 1_000e6, "ipfs://x");
        vm.prank(puppet);
        vm.expectRevert(AgentBond.NotArbiter.selector);
        bond.resolveClaim(id, 1_000e6, bytes32(0));
        // the open claim (filed during the delay) also blocks applying after the delay
        vm.warp(block.timestamp + 7 days);
        vm.prank(operator);
        vm.expectRevert(AgentBond.OpenClaims.selector);
        bond.applyArbiter(key);
        // old arbiter resolves it, then the change can be applied
        vm.prank(arbiter);
        bond.resolveClaim(id, 0, bytes32(0));
        vm.prank(operator);
        bond.applyArbiter(key);
        assertEq(bond.coverageOf(key).arbiter, puppet);
    }

    function test_M1_ownerCanCancelQueuedArbiter_andWalletCannotQueue() public {
        vm.prank(operator);
        bond.depositForAgent(agentId, arbiter, 100e6);
        bytes32 key = bond.keyOfAgent(agentId);
        address hot = makeAddr("hot-wallet");
        vm.prank(operator);
        registry.setAgentWallet(agentId, hot);
        vm.prank(hot);
        vm.expectRevert(AgentBond.NotOwner.selector);
        bond.setArbiter(key, puppet);
        vm.prank(operator);
        bond.setArbiter(key, puppet);
        vm.prank(operator);
        bond.setArbiter(key, arbiter); // cancel
        (address p, uint64 at) = bond.pendingArbiter(key);
        assertEq(p, address(0));
        assertEq(at, 0);
        vm.warp(block.timestamp + 8 days);
        vm.prank(operator);
        vm.expectRevert(AgentBond.NoPendingArbiter.selector);
        bond.applyArbiter(key);
    }

    // M-2: anyone could initialise someone else's bond and pick its arbiter.
    function test_M2_onlyControllerCanCreateBond() public {
        vm.prank(attacker);
        vm.expectRevert(AgentBond.NotController.selector);
        bond.depositForAgent(agentId, attacker, 1);
        vm.prank(attacker);
        vm.expectRevert(AgentBond.NotController.selector);
        bond.depositForAccount(operator, attacker, 1);
        // the real operator can still create it, and anyone can top up afterwards
        vm.prank(operator);
        bond.depositForAgent(agentId, arbiter, 100e6);
        vm.prank(attacker);
        bond.depositForAgent(agentId, address(0), 1e6);
        assertEq(bond.coverageOfAgent(agentId).arbiter, arbiter);
        assertEq(bond.coverageOfAgent(agentId).amount, 101e6);
    }

    // M-3: free claims kept openClaims > 0 forever. Now every spam claim costs the claim deposit.
    function test_M3_claimSpamCostsDeposit() public {
        vm.prank(operator);
        bond.depositForAgent(agentId, arbiter, 1_000e6);
        bytes32 key = bond.keyOfAgent(agentId);
        for (uint256 i; i < 5; i++) {
            vm.prank(attacker);
            uint256 id = bond.fileClaim(key, 1, "ipfs://spam");
            vm.prank(arbiter);
            bond.resolveClaim(id, 0, bytes32(0)); // reject -> deposit forfeits to the bond
        }
        assertEq(usdc.balanceOf(attacker), 5e6, "attacker paid 5 x 1 USDC");
        assertEq(bond.coverageOf(key).amount, 1_005e6, "victim bond grew by the forfeits");
        // cancel to dodge a rejection also forfeits
        vm.prank(attacker);
        uint256 id2 = bond.fileClaim(key, 1, "ipfs://spam");
        vm.prank(attacker);
        bond.cancelClaim(id2);
        assertEq(usdc.balanceOf(attacker), 4e6);
        // with no claims open the operator can withdraw
        vm.prank(operator);
        bond.requestWithdraw(key, 1_000e6);
        vm.warp(block.timestamp + 7 days);
        vm.prank(operator);
        bond.withdraw(key);
        assertEq(usdc.balanceOf(operator), 1_000e6);
        assertEq(usdc.balanceOf(address(bond)), 6e6);
    }

    function test_M3_depositRefundedOnSlashAndExpiry() public {
        vm.prank(operator);
        bond.depositForAgent(agentId, arbiter, 100e6);
        bytes32 key = bond.keyOfAgent(agentId);
        vm.prank(alt);
        uint256 id = bond.fileClaim(key, 40e6, "ipfs://ev");
        vm.prank(arbiter);
        bond.resolveClaim(id, 40e6, bytes32(0));
        assertEq(usdc.balanceOf(alt), 50e6, "slash + deposit back");
        vm.prank(alt);
        uint256 id2 = bond.fileClaim(key, 1e6, "ipfs://ev2");
        vm.warp(block.timestamp + 14 days);
        bond.expireClaim(id2);
        assertEq(usdc.balanceOf(alt), 50e6, "deposit back on expiry");
        assertEq(bond.heldClaimDeposits(), 0);
    }

    function testFuzz_M3_balanceCoversBondsAndDeposits(uint96 dep, uint8 n, uint256 seed) public {
        uint256 amt = bound(dep, 1e6, 1_000e6);
        n = uint8(bound(n, 1, 12));
        vm.prank(operator);
        bond.depositForAgent(agentId, arbiter, amt);
        bytes32 key = bond.keyOfAgent(agentId);
        usdc.mint(alt, uint256(n) * DEP);
        for (uint256 i; i < n; i++) {
            if (bond.coverageOf(key).amount == 0) break;
            vm.prank(alt);
            uint256 id = bond.fileClaim(key, 1e6, "ipfs://f");
            uint256 r = uint256(keccak256(abi.encode(seed, i))) % 4;
            if (r == 0) {
                vm.prank(arbiter);
                bond.resolveClaim(id, 0, 0);
            } else if (r == 1 && bond.coverageOf(key).amount >= 1e6) {
                vm.prank(arbiter);
                bond.resolveClaim(id, 1e6, 0);
            } else if (r == 2) {
                vm.prank(alt);
                bond.cancelClaim(id);
            }
        }
        assertEq(usdc.balanceOf(address(bond)), bond.coverageOf(key).amount + bond.heldClaimDeposits());
    }
}
