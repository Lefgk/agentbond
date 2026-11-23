// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AgentBond} from "../src/AgentBond.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {MockIdentityRegistry} from "../src/MockIdentityRegistry.sol";

contract AgentBondTest is Test {
    AgentBond internal bond;
    MockUSDC internal usdc;
    MockIdentityRegistry internal registry;

    uint64 internal constant COOLDOWN = 7 days;
    uint64 internal constant TIMEOUT = 14 days;
    uint256 internal constant CLAIM_DEP = 1e6;

    address internal operator = makeAddr("operator");
    address internal wallet = makeAddr("wallet");
    address internal arbiter = makeAddr("arbiter");
    address internal claimant = makeAddr("claimant");
    address internal stranger = makeAddr("stranger");
    address internal otherArb = makeAddr("other-arbiter");

    uint256 internal agentId;

    function setUp() public {
        usdc = new MockUSDC();
        registry = new MockIdentityRegistry();
        bond = new AgentBond(address(usdc), address(registry), COOLDOWN, TIMEOUT, CLAIM_DEP);

        agentId = registry.register(operator, "ipfs://agent");
        usdc.mint(operator, 1_000_000e6);
        usdc.mint(stranger, 1_000_000e6);
        usdc.mint(claimant, 100e6);
        vm.prank(operator);
        usdc.approve(address(bond), type(uint256).max);
        vm.prank(stranger);
        usdc.approve(address(bond), type(uint256).max);
        vm.prank(claimant);
        usdc.approve(address(bond), type(uint256).max);
    }

    function _depositAgent(uint256 amount) internal {
        vm.prank(operator);
        bond.depositForAgent(agentId, arbiter, amount);
    }

    function _depositAccount(address account, uint256 amount) internal {
        vm.prank(account);
        bond.depositForAccount(account, arbiter, amount);
    }

    function _agentKey() internal view returns (bytes32) {
        return bond.keyOfAgent(agentId);
    }

    // --- deposits ---

    function test_depositForAgent_setsCoverageAndArbiter() public {
        _depositAgent(100e6);
        AgentBond.Coverage memory c = bond.coverageOfAgent(agentId);
        assertEq(uint256(c.kind), uint256(AgentBond.Kind.AgentId));
        assertEq(c.agentId, agentId);
        assertEq(c.amount, 100e6);
        assertEq(c.totalDeposited, 100e6);
        assertEq(c.arbiter, arbiter);
        assertEq(c.operator, operator);
        assertEq(c.openClaims, 0);
        assertEq(usdc.balanceOf(address(bond)), 100e6);
    }

    function test_anyoneCanTopUp() public {
        _depositAgent(50e6);
        vm.prank(stranger);
        bond.depositForAgent(agentId, address(0), 25e6);
        AgentBond.Coverage memory c = bond.coverageOfAgent(agentId);
        assertEq(c.amount, 75e6);
        assertEq(c.totalDeposited, 75e6);
        assertEq(c.arbiter, arbiter);
    }

    function test_topUpWithDifferentArbiterReverts() public {
        _depositAgent(10e6);
        vm.prank(stranger);
        vm.expectRevert(AgentBond.ArbiterMismatch.selector);
        bond.depositForAgent(agentId, otherArb, 1e6);
    }

    function test_depositUnknownAgentReverts() public {
        vm.prank(operator);
        vm.expectRevert(AgentBond.UnknownAgent.selector);
        bond.depositForAgent(999, arbiter, 1e6);
    }

    function test_depositAgentIdZeroReverts() public {
        vm.prank(operator);
        vm.expectRevert(AgentBond.InvalidAgentId.selector);
        bond.depositForAgent(0, arbiter, 1e6);
    }

    function test_firstDepositRequiresArbiter() public {
        vm.prank(operator);
        vm.expectRevert(AgentBond.ZeroAddress.selector);
        bond.depositForAgent(agentId, address(0), 1e6);
    }

    function test_depositForAccount_fallbackKey() public {
        _depositAccount(operator, 40e6);
        AgentBond.Coverage memory c = bond.coverageOfAccount(operator);
        assertEq(uint256(c.kind), uint256(AgentBond.Kind.Account));
        assertEq(c.account, operator);
        assertEq(c.amount, 40e6);
        assertEq(c.operator, operator);
        assertEq(c.arbiter, arbiter);
    }

    function test_depositForAgent_registryUnsetReverts() public {
        AgentBond noReg = new AgentBond(address(usdc), address(0), COOLDOWN, TIMEOUT, CLAIM_DEP);
        vm.prank(operator);
        usdc.approve(address(noReg), type(uint256).max);
        vm.prank(operator);
        vm.expectRevert(AgentBond.RegistryNotSet.selector);
        noReg.depositForAgent(1, arbiter, 1e6);
        vm.prank(operator);
        noReg.depositForAccount(operator, arbiter, 1e6);
        assertEq(noReg.coverageOfAccount(operator).amount, 1e6);
    }

    // --- controllers ---

    function test_agentWalletCanManage() public {
        _depositAgent(20e6);
        bytes32 key = _agentKey();
        vm.prank(operator);
        registry.setAgentWallet(agentId, wallet);
        // audit M-1: the agent wallet (a hot key) can no longer change the arbiter; it can still withdraw-manage
        vm.prank(wallet);
        vm.expectRevert(AgentBond.NotOwner.selector);
        bond.setArbiter(key, otherArb);
        vm.prank(wallet);
        bond.requestWithdraw(key, 1e6);
        assertEq(bond.coverageOfAgent(agentId).pendingWithdraw, 1e6);
    }

    function test_afterTransfer_newOwnerControlsAndWalletCleared() public {
        _depositAgent(20e6);
        bytes32 key = _agentKey();
        vm.prank(operator);
        registry.setAgentWallet(agentId, wallet);
        address newOwner = makeAddr("new-owner");
        vm.prank(operator);
        registry.transfer(agentId, newOwner);

        vm.prank(wallet);
        vm.expectRevert(AgentBond.NotController.selector);
        bond.requestWithdraw(key, 1e6);

        vm.prank(operator);
        vm.expectRevert(AgentBond.NotController.selector);
        bond.requestWithdraw(key, 1e6);

        vm.prank(newOwner);
        bond.requestWithdraw(key, 5e6);
        assertEq(bond.coverageOfAgent(agentId).pendingWithdraw, 5e6);
        assertEq(bond.coverageOfAgent(agentId).operator, newOwner);
    }

    function test_strangerCannotSetArbiterOrWithdraw() public {
        _depositAgent(10e6);
        bytes32 key = _agentKey();
        vm.prank(stranger);
        vm.expectRevert(AgentBond.NotOwner.selector);
        bond.setArbiter(key, otherArb);
        vm.prank(stranger);
        vm.expectRevert(AgentBond.NotController.selector);
        bond.requestWithdraw(key, 1e6);
    }

    function test_setArbiterBlockedWhenOpenClaims() public {
        _depositAgent(10e6);
        bytes32 key = _agentKey();
        vm.prank(operator);
        bond.setArbiter(key, otherArb);
        vm.prank(claimant);
        bond.fileClaim(key, 1e6, "ipfs://ev");
        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(operator);
        vm.expectRevert(AgentBond.OpenClaims.selector);
        bond.applyArbiter(key);
    }

    // --- claims and slashes ---

    function test_unauthorizedResolveReverts() public {
        _depositAgent(100e6);
        bytes32 key = _agentKey();
        vm.prank(claimant);
        uint256 id = bond.fileClaim(key, 10e6, "ipfs://ev");
        vm.prank(stranger);
        vm.expectRevert(AgentBond.NotArbiter.selector);
        bond.resolveClaim(id, 10e6, keccak256("r"));
        vm.prank(operator);
        vm.expectRevert(AgentBond.NotArbiter.selector);
        bond.resolveClaim(id, 10e6, keccak256("r"));
    }

    function test_slashPaysClaimantAndReducesBond() public {
        _depositAgent(100e6);
        bytes32 key = _agentKey();
        uint256 before = usdc.balanceOf(claimant);
        vm.prank(claimant);
        uint256 id = bond.fileClaim(key, 40e6, "ipfs://proof");
        vm.prank(arbiter);
        bond.resolveClaim(id, 25e6, keccak256("breach"));
        AgentBond.Coverage memory c = bond.coverageOfAgent(agentId);
        assertEq(c.amount, 75e6);
        assertEq(c.totalSlashed, 25e6);
        assertEq(c.slashCount, 1);
        assertEq(c.openClaims, 0);
        assertEq(usdc.balanceOf(claimant), before + 25e6);
        AgentBond.SlashRecord[] memory hist = bond.slashHistoryOfAgent(agentId);
        assertEq(hist.length, 1);
        assertEq(hist[0].amount, 25e6);
        assertEq(hist[0].claimant, claimant);
        assertEq(hist[0].reasonHash, keccak256("breach"));
        assertEq(hist[0].claimId, id);
    }

    function test_rejectClaimDoesNotSlash() public {
        _depositAgent(50e6);
        bytes32 key = _agentKey();
        vm.prank(claimant);
        uint256 id = bond.fileClaim(key, 50e6, "ipfs://ev");
        vm.prank(arbiter);
        bond.resolveClaim(id, 0, keccak256("no"));
        AgentBond.Coverage memory c = bond.coverageOfAgent(agentId);
        assertEq(c.amount, 50e6 + CLAIM_DEP); // forfeited claim deposit joins the bond
        assertEq(c.totalSlashed, 0);
        assertEq(uint256(bond.getClaim(id).status), uint256(AgentBond.ClaimStatus.Rejected));
        assertEq(bond.slashHistoryOfAgent(agentId).length, 0);
    }

    function test_slashCannotExceedRequestedOrBond() public {
        _depositAgent(10e6);
        bytes32 key = _agentKey();
        vm.prank(claimant);
        uint256 id = bond.fileClaim(key, 8e6, "ipfs://ev");
        vm.prank(arbiter);
        vm.expectRevert(abi.encodeWithSelector(AgentBond.ExceedsRequested.selector, 9e6, 8e6));
        bond.resolveClaim(id, 9e6, bytes32(0));

        // file a claim larger than the remaining bond and try to slash more than remaining
        vm.prank(arbiter);
        bond.resolveClaim(id, 0, bytes32(0));
        vm.prank(claimant);
        uint256 id2 = bond.fileClaim(key, 50e6, "ipfs://big");
        vm.prank(arbiter);
        vm.expectRevert(abi.encodeWithSelector(AgentBond.ExceedsBond.selector, 11e6 + CLAIM_DEP, 10e6 + CLAIM_DEP));
        bond.resolveClaim(id2, 11e6 + CLAIM_DEP, bytes32(0)); // remaining = 10e6 + forfeited deposit
    }

    function test_fileClaimValidations() public {
        _depositAgent(10e6);
        bytes32 key = _agentKey();
        vm.prank(arbiter);
        vm.expectRevert(AgentBond.ArbiterCannotClaim.selector);
        bond.fileClaim(key, 1e6, "ipfs://x");
        vm.prank(operator);
        vm.expectRevert(AgentBond.ControllerCannotClaim.selector);
        bond.fileClaim(key, 1e6, "ipfs://x");
        vm.prank(claimant);
        vm.expectRevert(AgentBond.InvalidEvidence.selector);
        bond.fileClaim(key, 1e6, "");
        vm.prank(claimant);
        vm.expectRevert(AgentBond.ZeroAmount.selector);
        bond.fileClaim(key, 0, "ipfs://x");
    }

    function test_claimantCanCancelToUnblockWithdraw() public {
        _depositAgent(10e6);
        bytes32 key = _agentKey();
        vm.prank(claimant);
        uint256 id = bond.fileClaim(key, 1e6, "ipfs://ev");
        vm.prank(operator);
        vm.expectRevert(AgentBond.OpenClaims.selector);
        bond.requestWithdraw(key, 10e6);
        vm.prank(claimant);
        bond.cancelClaim(id);
        vm.prank(operator);
        bond.requestWithdraw(key, 10e6);
        assertEq(bond.coverageOf(key).openClaims, 0);
    }

    function test_expireClaimAfterTimeout() public {
        _depositAgent(10e6);
        bytes32 key = _agentKey();
        vm.prank(claimant);
        uint256 id = bond.fileClaim(key, 1e6, "ipfs://ev");
        vm.prank(stranger);
        vm.expectRevert(AgentBond.ClaimNotExpired.selector);
        bond.expireClaim(id);
        vm.warp(block.timestamp + TIMEOUT);
        vm.prank(stranger);
        bond.expireClaim(id);
        assertEq(uint256(bond.getClaim(id).status), uint256(AgentBond.ClaimStatus.Expired));
        vm.prank(operator);
        bond.requestWithdraw(key, 10e6);
    }

    // --- cooldown ---

    function test_withdrawCooldownEnforced() public {
        _depositAgent(80e6);
        bytes32 key = _agentKey();
        vm.prank(operator);
        bond.requestWithdraw(key, 30e6);
        vm.prank(operator);
        vm.expectRevert(AgentBond.CooldownActive.selector);
        bond.withdraw(key);
        vm.warp(block.timestamp + COOLDOWN - 1);
        vm.prank(operator);
        vm.expectRevert(AgentBond.CooldownActive.selector);
        bond.withdraw(key);
        vm.warp(block.timestamp + 1);
        uint256 before = usdc.balanceOf(operator);
        vm.prank(operator);
        bond.withdraw(key);
        assertEq(usdc.balanceOf(operator), before + 30e6);
        assertEq(bond.coverageOf(key).amount, 50e6);
        assertEq(bond.coverageOf(key).pendingWithdraw, 0);
    }

    function test_openClaimsBlockRequestAndFinalize() public {
        _depositAgent(80e6);
        bytes32 key = _agentKey();
        vm.prank(operator);
        bond.requestWithdraw(key, 80e6);
        vm.prank(claimant);
        uint256 id = bond.fileClaim(key, 10e6, "ipfs://ev");
        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(operator);
        vm.expectRevert(AgentBond.OpenClaims.selector);
        bond.withdraw(key);
        vm.prank(operator);
        vm.expectRevert(AgentBond.OpenClaims.selector);
        bond.requestWithdraw(key, 10e6);
        vm.prank(arbiter);
        bond.resolveClaim(id, 10e6, keccak256("ok"));
        // remaining 70 after slash; pending was 80 so finalize pays 70
        uint256 before = usdc.balanceOf(operator);
        vm.prank(operator);
        bond.withdraw(key);
        assertEq(usdc.balanceOf(operator), before + 70e6);
        assertEq(bond.coverageOf(key).amount, 0);
    }

    function test_cancelWithdraw() public {
        _depositAgent(10e6);
        bytes32 key = _agentKey();
        vm.prank(operator);
        bond.requestWithdraw(key, 10e6);
        vm.prank(operator);
        bond.cancelWithdraw(key);
        assertEq(bond.coverageOf(key).withdrawAvailableAt, 0);
        vm.prank(operator);
        vm.expectRevert(AgentBond.NoPendingWithdraw.selector);
        bond.withdraw(key);
    }

    function test_zeroAmountAndUnknownBondReverts() public {
        vm.prank(operator);
        vm.expectRevert(AgentBond.ZeroAmount.selector);
        bond.depositForAccount(operator, arbiter, 0);
        bytes32 acctKey = bond.keyOfAccount(operator);
        vm.prank(operator);
        vm.expectRevert(AgentBond.UnknownBond.selector);
        bond.requestWithdraw(acctKey, 1);
    }

    function test_constructorGuards() public {
        vm.expectRevert(AgentBond.ZeroAddress.selector);
        new AgentBond(address(0), address(registry), COOLDOWN, TIMEOUT, CLAIM_DEP);
        vm.expectRevert(AgentBond.InvalidAmount.selector);
        new AgentBond(address(usdc), address(registry), 0, TIMEOUT, CLAIM_DEP);
        vm.expectRevert(AgentBond.InvalidAmount.selector);
        new AgentBond(address(usdc), address(registry), COOLDOWN, 0, CLAIM_DEP);
    }

    // --- fuzz ---

    function testFuzz_slashNeverExceedsBond(uint256 deposit, uint256 requested, uint256 slashAmount) public {
        bytes32 key = _agentKey();
        deposit = bound(deposit, 1, 500_000e6);
        requested = bound(requested, 1, 1_000_000e6);
        slashAmount = bound(slashAmount, 0, requested + deposit);

        vm.prank(operator);
        bond.depositForAgent(agentId, arbiter, deposit);
        vm.prank(claimant);
        uint256 id = bond.fileClaim(key, requested, "ipfs://fuzz");

        if (slashAmount > requested || slashAmount > deposit) {
            vm.prank(arbiter);
            vm.expectRevert();
            bond.resolveClaim(id, slashAmount, keccak256("f"));
            assertEq(bond.coverageOfAgent(agentId).amount, deposit);
            assertEq(bond.coverageOfAgent(agentId).totalSlashed, 0);
            assertEq(usdc.balanceOf(address(bond)), deposit + CLAIM_DEP);
        } else {
            vm.prank(arbiter);
            bond.resolveClaim(id, slashAmount, keccak256("f"));
            AgentBond.Coverage memory c = bond.coverageOfAgent(agentId);
            assertEq(c.totalSlashed, slashAmount);
            assertLe(c.totalSlashed, c.totalDeposited);
            if (slashAmount == 0) {
                // rejection: the claim deposit is added to the bond
                assertEq(c.amount, deposit + CLAIM_DEP);
                assertEq(usdc.balanceOf(address(bond)), deposit + CLAIM_DEP);
                assertEq(usdc.balanceOf(claimant), 100e6 - CLAIM_DEP);
            } else {
                assertEq(c.amount, deposit - slashAmount);
                assertEq(usdc.balanceOf(address(bond)), deposit - slashAmount);
                assertEq(usdc.balanceOf(claimant), 100e6 + slashAmount);
            }
        }
    }

    function testFuzz_slashSequenceNeverExceedsBond(uint256 deposit, uint256 nSeed, uint256 a, uint256 b, uint256 c)
        public
    {
        bytes32 key = _agentKey();
        deposit = bound(deposit, 3, 200_000e6);
        uint256 n = bound(nSeed, 1, 3);
        uint256[3] memory reqs = [bound(a, 1, deposit), bound(b, 1, deposit), bound(c, 1, deposit)];
        vm.prank(operator);
        bond.depositForAgent(agentId, arbiter, deposit);
        uint256 remaining = deposit;
        uint256 slashed;
        for (uint256 i; i < n; i++) {
            if (remaining == 0) break;
            vm.prank(claimant);
            uint256 id = bond.fileClaim(key, reqs[i], "ipfs://s");
            uint256 take = reqs[i] > remaining ? remaining : reqs[i];
            vm.prank(arbiter);
            bond.resolveClaim(id, take, bytes32(i));
            remaining -= take;
            slashed += take;
        }
        AgentBond.Coverage memory cov = bond.coverageOfAgent(agentId);
        assertEq(cov.amount, remaining);
        assertEq(cov.totalSlashed, slashed);
        assertLe(cov.totalSlashed, cov.totalDeposited);
        assertEq(usdc.balanceOf(address(bond)), remaining);
    }

    function testFuzz_cooldownEnforced(uint64 elapsed, uint256 amount) public {
        amount = bound(amount, 1, 10_000e6);
        elapsed = uint64(bound(elapsed, 0, uint256(COOLDOWN) * 4));
        vm.prank(operator);
        bond.depositForAgent(agentId, arbiter, amount);
        bytes32 key = _agentKey();
        vm.prank(operator);
        bond.requestWithdraw(key, amount);
        uint64 requestedAt = uint64(block.timestamp);
        vm.warp(requestedAt + elapsed);
        if (elapsed < COOLDOWN) {
            vm.prank(operator);
            vm.expectRevert(AgentBond.CooldownActive.selector);
            bond.withdraw(key);
            assertEq(bond.coverageOf(key).amount, amount);
        } else {
            uint256 before = usdc.balanceOf(operator);
            vm.prank(operator);
            bond.withdraw(key);
            assertEq(usdc.balanceOf(operator), before + amount);
            assertEq(bond.coverageOf(key).amount, 0);
        }
    }

    function testFuzz_openClaimsAlwaysBlockWithdraw(uint256 deposit, uint256 claimAmt) public {
        deposit = bound(deposit, 1, 50_000e6);
        claimAmt = bound(claimAmt, 1, 50_000e6);
        vm.prank(operator);
        bond.depositForAgent(agentId, arbiter, deposit);
        bytes32 key = _agentKey();
        vm.prank(claimant);
        bond.fileClaim(key, claimAmt, "ipfs://block");
        vm.prank(operator);
        vm.expectRevert(AgentBond.OpenClaims.selector);
        bond.requestWithdraw(key, deposit);
    }
}
