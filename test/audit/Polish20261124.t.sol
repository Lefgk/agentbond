// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AgentBond} from "../../src/AgentBond.sol";
import {MockUSDC} from "../../src/MockUSDC.sol";
import {MockIdentityRegistry} from "../../src/MockIdentityRegistry.sol";

/// USDT-shaped token: 6 decimals, transfer/transferFrom/approve return NOTHING.
contract NoReturnToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint8 public constant decimals = 6;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external {
        allowance[msg.sender][s] = a;
    }

    function transfer(address to, uint256 a) external {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
    }

    function transferFrom(address f, address to, uint256 a) external {
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[to] += a;
    }
}

/// USDC-shaped token with a blacklist (6 decimals) and an optional re-entry hook on transfer.
contract HookBlacklistToken is MockUSDC {
    mapping(address => bool) public blacklisted;
    address public hookTarget;
    bytes public hookData;
    bool public hookReverted;
    bool public hookFired;

    function setBlacklist(address a, bool v) external {
        blacklisted[a] = v;
    }

    function setHook(address t, bytes calldata d) external {
        hookTarget = t;
        hookData = d;
    }

    function _update(address from, address to, uint256 v) internal override {
        require(!blacklisted[from] && !blacklisted[to], "blacklisted");
        super._update(from, to, v);
        if (hookTarget != address(0) && from == hookTarget && !hookFired) {
            hookFired = true;
            // The token is the one receiving control mid-payout; try to re-enter as the payee.
            (bool ok,) = hookTarget.call(hookData);
            hookReverted = !ok;
        }
    }
}

contract AgentBondPolish20261124 is Test {
    AgentBond bond;
    MockUSDC usdc;
    MockIdentityRegistry registry;

    uint64 constant COOLDOWN = 7 days;
    uint64 constant TIMEOUT = 14 days;
    uint256 constant DEP = 1e6;

    address operator = makeAddr("operator");
    address hot = makeAddr("hot");
    address arbiter = makeAddr("arbiter");
    address claimant = makeAddr("claimant");
    address stranger = makeAddr("stranger");
    address buyer = makeAddr("buyer");
    address puppet = makeAddr("puppet");
    uint256 agentId;
    bytes32 key;

    function setUp() public {
        usdc = new MockUSDC();
        registry = new MockIdentityRegistry();
        bond = new AgentBond(address(usdc), address(registry), COOLDOWN, TIMEOUT, DEP);
        agentId = registry.register(operator, "ipfs://a");
        key = bond.keyOfAgent(agentId);
        _fund(usdc, bond);
    }

    function _fund(MockUSDC t, AgentBond b) internal {
        address[4] memory a = [operator, claimant, stranger, buyer];
        for (uint256 i; i < a.length; i++) {
            t.mint(a[i], 1_000_000_000e6);
            vm.prank(a[i]);
            t.approve(address(b), type(uint256).max);
        }
    }

    function _dep(uint256 amt) internal {
        vm.prank(operator);
        bond.depositForAgent(agentId, arbiter, amt);
    }

    function _file(uint256 amt) internal returns (uint256 id) {
        vm.prank(claimant);
        id = bond.fileClaim(key, amt, "ipfs://e");
    }

    // ---------- deposits ----------

    function test_zeroDepositReverts_agentAndAccount() public {
        vm.startPrank(operator);
        vm.expectRevert(AgentBond.ZeroAmount.selector);
        bond.depositForAgent(agentId, arbiter, 0);
        vm.expectRevert(AgentBond.ZeroAmount.selector);
        bond.depositForAccount(operator, arbiter, 0);
        vm.stopPrank();
    }

    function test_depositForAccount_zeroAccountReverts() public {
        vm.expectRevert(AgentBond.ZeroAddress.selector);
        bond.depositForAccount(address(0), arbiter, 1);
    }

    function test_depositRevertsWithoutAllowanceOrBalance() public {
        address poor = makeAddr("poor");
        vm.prank(poor);
        vm.expectRevert();
        bond.depositForAccount(poor, arbiter, 1e6);
        // state untouched: key stays unknown
        assertEq(bond.coverageOfAccount(poor).arbiter, address(0));
    }

    function test_topUpWithZeroArbiterKeepsArbiter() public {
        _dep(10e6);
        vm.prank(stranger);
        bond.depositForAgent(agentId, address(0), 5e6);
        assertEq(bond.coverageOf(key).arbiter, arbiter);
        assertEq(bond.coverageOf(key).amount, 15e6);
        assertEq(usdc.balanceOf(address(bond)), 15e6);
    }

    function test_topUpSameArbiterExplicitOk() public {
        _dep(10e6);
        vm.prank(stranger);
        bond.depositForAgent(agentId, arbiter, 1e6);
        assertEq(bond.coverageOf(key).totalDeposited, 11e6);
    }

    function test_agentWalletCanCreateBondButOnlyOwnerCanSetArbiter() public {
        vm.prank(operator);
        registry.setAgentWallet(agentId, hot);
        vm.prank(hot);
        usdc.approve(address(bond), 0); // no-op, hot has no funds
        usdc.mint(hot, 5e6);
        vm.prank(hot);
        usdc.approve(address(bond), type(uint256).max);
        vm.prank(hot);
        bond.depositForAgent(agentId, arbiter, 5e6);
        assertTrue(bond.isController(key, hot));
        vm.prank(hot);
        vm.expectRevert(AgentBond.NotOwner.selector);
        bond.setArbiter(key, puppet);
        vm.prank(hot);
        vm.expectRevert(AgentBond.NotOwner.selector);
        bond.applyArbiter(key);
    }

    function test_isController_unknownBondFalse() public view {
        assertFalse(bond.isController(bytes32(uint256(1)), operator));
    }

    // ---------- claims ----------

    function test_fileClaim_unknownBondReverts() public {
        vm.prank(claimant);
        vm.expectRevert(AgentBond.UnknownBond.selector);
        bond.fileClaim(bytes32(uint256(7)), 1, "x");
    }

    function test_fileClaim_uriLengthBoundary() public {
        _dep(10e6);
        bytes memory ok = new bytes(512);
        for (uint256 i; i < 512; i++) ok[i] = "a";
        vm.prank(claimant);
        bond.fileClaim(key, 1, string(ok));
        bytes memory bad = new bytes(513);
        for (uint256 i; i < 513; i++) bad[i] = "a";
        vm.prank(claimant);
        vm.expectRevert(AgentBond.InvalidEvidence.selector);
        bond.fileClaim(key, 1, string(bad));
    }

    function test_fileClaim_emptyBondAfterFullSlashReverts() public {
        _dep(10e6);
        uint256 id = _file(10e6);
        vm.prank(arbiter);
        bond.resolveClaim(id, 10e6, bytes32("r"));
        assertEq(bond.coverageOf(key).amount, 0);
        vm.prank(claimant);
        vm.expectRevert(AgentBond.EmptyBond.selector);
        bond.fileClaim(key, 1, "x");
    }

    function test_fileClaim_walletControllerCannotClaim() public {
        _dep(10e6);
        vm.prank(operator);
        registry.setAgentWallet(agentId, hot);
        vm.prank(hot);
        vm.expectRevert(AgentBond.ControllerCannotClaim.selector);
        bond.fileClaim(key, 1, "x");
    }

    function test_fileClaim_needsDepositAllowance() public {
        _dep(10e6);
        vm.prank(claimant);
        usdc.approve(address(bond), DEP - 1);
        vm.prank(claimant);
        vm.expectRevert();
        bond.fileClaim(key, 1, "x");
        // the failed filing left no trace
        assertEq(bond.claimCount(), 0);
        assertEq(bond.coverageOf(key).openClaims, 0);
        assertEq(bond.heldClaimDeposits(), 0);
    }

    function test_resolve_unknownClaim_andDoubleResolve() public {
        _dep(10e6);
        vm.prank(arbiter);
        vm.expectRevert(AgentBond.UnknownClaim.selector);
        bond.resolveClaim(99, 0, 0);
        uint256 id = _file(5e6);
        vm.prank(arbiter);
        bond.resolveClaim(id, 1e6, 0);
        vm.prank(arbiter);
        vm.expectRevert(AgentBond.NotPending.selector);
        bond.resolveClaim(id, 1e6, 0);
        vm.prank(claimant);
        vm.expectRevert(AgentBond.NotPending.selector);
        bond.cancelClaim(id);
        vm.expectRevert(AgentBond.NotPending.selector);
        bond.expireClaim(id);
    }

    function test_resolve_wrongCallers() public {
        _dep(10e6);
        uint256 id = _file(5e6);
        address[4] memory bad = [operator, claimant, stranger, hot];
        for (uint256 i; i < bad.length; i++) {
            vm.prank(bad[i]);
            vm.expectRevert(AgentBond.NotArbiter.selector);
            bond.resolveClaim(id, 1, 0);
        }
    }

    function test_cancelClaim_onlyClaimant() public {
        _dep(10e6);
        uint256 id = _file(5e6);
        vm.prank(arbiter);
        vm.expectRevert(AgentBond.NotClaimant.selector);
        bond.cancelClaim(id);
        vm.prank(operator);
        vm.expectRevert(AgentBond.NotClaimant.selector);
        bond.cancelClaim(id);
    }

    function test_rejectAndCancel_forfeitDepositToBond_exactAccounting() public {
        _dep(10e6);
        uint256 id1 = _file(5e6);
        uint256 id2 = _file(5e6);
        uint256 before = usdc.balanceOf(claimant);
        vm.prank(arbiter);
        bond.resolveClaim(id1, 0, bytes32("no"));
        vm.prank(claimant);
        bond.cancelClaim(id2);
        AgentBond.Coverage memory c = bond.coverageOf(key);
        assertEq(c.amount, 10e6 + 2 * DEP);
        assertEq(c.totalDeposited, 10e6 + 2 * DEP);
        assertEq(c.openClaims, 0);
        assertEq(usdc.balanceOf(claimant), before, "claimant never gets deposit back");
        assertEq(bond.heldClaimDeposits(), 0);
        assertEq(usdc.balanceOf(address(bond)), c.amount);
    }

    function test_expireClaim_exactBoundary_anyoneCanCall_refundsClaimant() public {
        _dep(10e6);
        uint256 t0 = block.timestamp;
        uint256 id = _file(5e6);
        uint256 balAfterFile = usdc.balanceOf(claimant);
        vm.warp(t0 + TIMEOUT - 1);
        vm.prank(stranger);
        vm.expectRevert(AgentBond.ClaimNotExpired.selector);
        bond.expireClaim(id);
        vm.warp(t0 + TIMEOUT);
        vm.prank(stranger);
        bond.expireClaim(id);
        assertEq(usdc.balanceOf(claimant), balAfterFile + DEP);
        assertEq(uint8(bond.getClaim(id).status), uint8(AgentBond.ClaimStatus.Expired));
        // arbiter can no longer slash an expired claim
        vm.prank(arbiter);
        vm.expectRevert(AgentBond.NotPending.selector);
        bond.resolveClaim(id, 1, 0);
    }

    function test_slash_pays_exactlySlashPlusDeposit_andRecordsHistory() public {
        _dep(10e6);
        uint256 id = _file(4e6);
        uint256 before = usdc.balanceOf(claimant);
        vm.prank(arbiter);
        bond.resolveClaim(id, 3e6, bytes32("why"));
        assertEq(usdc.balanceOf(claimant), before + 3e6 + DEP);
        AgentBond.SlashRecord[] memory h = bond.slashHistoryOfAgent(agentId);
        assertEq(h.length, 1);
        assertEq(h[0].amount, 3e6);
        assertEq(h[0].claimId, id);
        assertEq(h[0].claimant, claimant);
        assertEq(bond.getBond(key).slashCount, 1);
        assertEq(bond.getBond(key).totalSlashed, 3e6);
    }

    function test_noClaimDeposit_variant() public {
        AgentBond b0 = new AgentBond(address(usdc), address(registry), COOLDOWN, TIMEOUT, 0);
        vm.prank(operator);
        usdc.approve(address(b0), type(uint256).max);
        vm.prank(operator);
        b0.depositForAgent(agentId, arbiter, 10e6);
        bytes32 k = b0.keyOfAgent(agentId);
        uint256 before = usdc.balanceOf(stranger);
        vm.prank(stranger); // no allowance needed
        usdc.approve(address(b0), 0);
        vm.prank(stranger);
        uint256 id = b0.fileClaim(k, 4e6, "x");
        assertEq(b0.claimDepositOf(id), 0);
        vm.prank(arbiter);
        b0.resolveClaim(id, 4e6, 0);
        assertEq(usdc.balanceOf(stranger), before + 4e6);
        assertEq(usdc.balanceOf(address(b0)), 6e6);
    }

    // ---------- withdraw ----------

    function test_requestWithdraw_bounds_andAuth() public {
        _dep(10e6);
        vm.startPrank(operator);
        vm.expectRevert(AgentBond.InvalidAmount.selector);
        bond.requestWithdraw(key, 0);
        vm.expectRevert(AgentBond.InvalidAmount.selector);
        bond.requestWithdraw(key, 10e6 + 1);
        bond.requestWithdraw(key, 10e6); // max ok
        vm.stopPrank();
        vm.prank(stranger);
        vm.expectRevert(AgentBond.NotController.selector);
        bond.requestWithdraw(key, 1);
        vm.prank(stranger);
        vm.expectRevert(AgentBond.NotController.selector);
        bond.cancelWithdraw(key);
        vm.prank(arbiter);
        vm.expectRevert(AgentBond.NotController.selector);
        bond.withdraw(key);
    }

    function test_withdraw_withoutRequest_andCancelWithoutRequest() public {
        _dep(10e6);
        vm.startPrank(operator);
        vm.expectRevert(AgentBond.NoPendingWithdraw.selector);
        bond.withdraw(key);
        vm.expectRevert(AgentBond.NoPendingWithdraw.selector);
        bond.cancelWithdraw(key);
        vm.stopPrank();
    }

    function test_withdraw_exactCooldownBoundary_andNoDoubleWithdraw() public {
        _dep(10e6);
        uint256 t0 = block.timestamp;
        vm.prank(operator);
        bond.requestWithdraw(key, 4e6);
        vm.warp(t0 + COOLDOWN - 1);
        vm.prank(operator);
        vm.expectRevert(AgentBond.CooldownActive.selector);
        bond.withdraw(key);
        vm.warp(t0 + COOLDOWN);
        vm.prank(operator);
        bond.withdraw(key);
        vm.prank(operator);
        vm.expectRevert(AgentBond.NoPendingWithdraw.selector);
        bond.withdraw(key);
        assertEq(bond.coverageOf(key).amount, 6e6);
    }

    function test_withdraw_paysCurrentOwner_notCaller_afterNftTransfer() public {
        _dep(10e6);
        vm.prank(operator);
        bond.requestWithdraw(key, 10e6);
        vm.prank(operator);
        registry.transfer(agentId, buyer);
        vm.warp(block.timestamp + COOLDOWN);
        // old owner lost control
        vm.prank(operator);
        vm.expectRevert(AgentBond.NotController.selector);
        bond.withdraw(key);
        uint256 before = usdc.balanceOf(buyer);
        vm.prank(buyer);
        bond.withdraw(key);
        assertEq(usdc.balanceOf(buyer), before + 10e6);
    }

    function test_withdraw_agentWalletCallerPaysOwner() public {
        _dep(10e6);
        vm.prank(operator);
        registry.setAgentWallet(agentId, hot);
        vm.prank(hot);
        bond.requestWithdraw(key, 10e6);
        vm.warp(block.timestamp + COOLDOWN);
        uint256 opBefore = usdc.balanceOf(operator);
        vm.prank(hot);
        bond.withdraw(key);
        assertEq(usdc.balanceOf(operator), opBefore + 10e6);
        assertEq(usdc.balanceOf(hot), 0);
    }

    /// Request first, claim filed during cooldown, slash lands: withdraw is capped to what is left.
    function test_withdraw_cappedAfterSlash_thenZeroAmountReverts() public {
        _dep(100e6);
        vm.prank(operator);
        bond.requestWithdraw(key, 100e6);
        uint256 id = _file(40e6);
        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(operator);
        vm.expectRevert(AgentBond.OpenClaims.selector);
        bond.withdraw(key);
        vm.prank(arbiter);
        bond.resolveClaim(id, 40e6, 0);
        uint256 before = usdc.balanceOf(operator);
        vm.prank(operator);
        bond.withdraw(key);
        assertEq(usdc.balanceOf(operator), before + 60e6);
        assertEq(usdc.balanceOf(address(bond)), 0);

        // second scenario: slash everything while a withdraw is pending -> ZeroAmount
        vm.prank(operator);
        bond.depositForAgent(agentId, address(0), 10e6);
        vm.prank(operator);
        bond.requestWithdraw(key, 10e6);
        uint256 id2 = _file(10e6);
        vm.prank(arbiter);
        bond.resolveClaim(id2, 10e6, 0);
        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(operator);
        vm.expectRevert(AgentBond.ZeroAmount.selector);
        bond.withdraw(key);
    }

    function test_requestWithdraw_overwritesPreviousRequestAndResetsTimer() public {
        _dep(10e6);
        uint256 t0 = block.timestamp;
        vm.prank(operator);
        bond.requestWithdraw(key, 3e6);
        vm.warp(t0 + 5 days);
        vm.prank(operator);
        bond.requestWithdraw(key, 9e6);
        AgentBond.Coverage memory c = bond.coverageOf(key);
        assertEq(c.pendingWithdraw, 9e6);
        assertEq(c.withdrawAvailableAt, t0 + 5 days + COOLDOWN);
    }

    // ---------- arbiter rotation ----------

    function test_setArbiter_validations() public {
        vm.prank(operator);
        vm.expectRevert(AgentBond.UnknownBond.selector);
        bond.setArbiter(key, puppet);
        _dep(1e6);
        vm.startPrank(operator);
        vm.expectRevert(AgentBond.ZeroAddress.selector);
        bond.setArbiter(key, address(0));
        vm.expectRevert(AgentBond.NoPendingArbiter.selector);
        bond.setArbiter(key, arbiter); // cancel with nothing queued
        vm.expectRevert(AgentBond.NoPendingArbiter.selector);
        bond.applyArbiter(key);
        vm.stopPrank();
    }

    function test_applyArbiter_exactBoundary_requeueResetsTimer_cancelClears() public {
        _dep(1e6);
        uint256 t0 = block.timestamp;
        vm.prank(operator);
        bond.setArbiter(key, puppet);
        vm.warp(t0 + 3 days);
        address p2 = makeAddr("p2");
        vm.prank(operator);
        bond.setArbiter(key, p2); // requeue
        (address pa, uint64 at) = bond.pendingArbiter(key);
        assertEq(pa, p2);
        assertEq(at, t0 + 3 days + COOLDOWN);
        vm.warp(at - 1);
        vm.prank(operator);
        vm.expectRevert(AgentBond.ArbiterCooldownActive.selector);
        bond.applyArbiter(key);
        vm.warp(at);
        vm.prank(stranger);
        vm.expectRevert(AgentBond.NotOwner.selector);
        bond.applyArbiter(key);
        vm.prank(operator);
        bond.applyArbiter(key);
        assertEq(bond.coverageOf(key).arbiter, p2);
        (pa, at) = bond.pendingArbiter(key);
        assertEq(pa, address(0));
        assertEq(at, 0);
        // cancel path
        vm.prank(operator);
        bond.setArbiter(key, puppet);
        vm.prank(operator);
        bond.setArbiter(key, p2);
        (pa, at) = bond.pendingArbiter(key);
        assertEq(at, 0);
        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(operator);
        vm.expectRevert(AgentBond.NoPendingArbiter.selector);
        bond.applyArbiter(key);
    }

    function test_oldArbiterLosesPowerAfterApply_newArbiterGainsIt() public {
        _dep(10e6);
        vm.prank(operator);
        bond.setArbiter(key, puppet);
        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(operator);
        bond.applyArbiter(key);
        uint256 id = _file(1e6);
        vm.prank(arbiter);
        vm.expectRevert(AgentBond.NotArbiter.selector);
        bond.resolveClaim(id, 1, 0);
        vm.prank(puppet);
        bond.resolveClaim(id, 1, 0);
        // the former arbiter may now file claims; the new one may not
        usdc.mint(arbiter, DEP);
        vm.prank(arbiter);
        usdc.approve(address(bond), DEP);
        vm.prank(arbiter);
        bond.fileClaim(key, 1, "x");
        vm.prank(puppet);
        vm.expectRevert(AgentBond.ArbiterCannotClaim.selector);
        bond.fileClaim(key, 1, "x");
    }

    /// L-4 (acknowledged): a queued change survives an NFT sale; new owner must cancel it.
    function test_L4_queuedArbiterSurvivesTransfer_previousOwnerCannotApply_newOwnerCanCancel() public {
        _dep(10e6);
        vm.prank(operator);
        bond.setArbiter(key, puppet);
        vm.prank(operator);
        registry.transfer(agentId, buyer);
        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(operator);
        vm.expectRevert(AgentBond.NotOwner.selector);
        bond.applyArbiter(key);
        (address pa,) = bond.pendingArbiter(key);
        assertEq(pa, puppet, "still queued");
        vm.prank(buyer);
        bond.setArbiter(key, arbiter); // cancel
        (pa,) = bond.pendingArbiter(key);
        assertEq(pa, address(0));
    }

    // ---------- L-2: unreadable owner (burn) ----------

    function test_L2_burnedAgent_bondStuckButSlashableAndViewsDoNotRevert() public {
        _dep(10e6);
        vm.mockCallRevert(address(registry), abi.encodeWithSelector(registry.ownerOf.selector, agentId), "burned");
        vm.prank(operator);
        vm.expectRevert(AgentBond.NotController.selector);
        bond.requestWithdraw(key, 1);
        vm.prank(operator);
        vm.expectRevert(AgentBond.NotOwner.selector);
        bond.setArbiter(key, puppet);
        assertEq(bond.coverageOf(key).operator, address(0));
        assertFalse(bond.isController(key, operator));
        // claims still resolve
        uint256 id = _file(2e6);
        vm.prank(arbiter);
        bond.resolveClaim(id, 2e6, 0);
        assertEq(bond.coverageOf(key).amount, 8e6);
    }

    // ---------- L-3: blacklist ----------

    function test_L3_blacklistedClaimant_resolveSlashReverts_butRejectAndExpireBehave() public {
        HookBlacklistToken t = new HookBlacklistToken();
        AgentBond b = new AgentBond(address(t), address(registry), COOLDOWN, TIMEOUT, DEP);
        address[2] memory a = [operator, claimant];
        for (uint256 i; i < 2; i++) {
            t.mint(a[i], 100e6);
            vm.prank(a[i]);
            t.approve(address(b), type(uint256).max);
        }
        vm.prank(operator);
        b.depositForAgent(agentId, arbiter, 50e6);
        bytes32 k = b.keyOfAgent(agentId);
        vm.prank(claimant);
        uint256 id = b.fileClaim(k, 10e6, "x");
        t.setBlacklist(claimant, true);
        vm.prank(arbiter);
        vm.expectRevert(bytes("blacklisted"));
        b.resolveClaim(id, 10e6, 0);
        // arbiter can still clear the claim by rejecting (deposit stays with the bond)
        vm.prank(arbiter);
        b.resolveClaim(id, 0, 0);
        assertEq(b.coverageOf(k).openClaims, 0);
        assertEq(b.coverageOf(k).amount, 50e6 + DEP);
    }

    // ---------- reentrancy via token hook ----------

    function test_reentrancy_withdrawPayoutCannotReenter() public {
        HookBlacklistToken t = new HookBlacklistToken();
        AgentBond b = new AgentBond(address(t), address(0), COOLDOWN, TIMEOUT, 0);
        t.mint(operator, 100e6);
        vm.prank(operator);
        t.approve(address(b), type(uint256).max);
        vm.prank(operator);
        b.depositForAccount(operator, arbiter, 100e6);
        bytes32 k = b.keyOfAccount(operator);
        vm.prank(operator);
        b.requestWithdraw(k, 100e6);
        vm.warp(block.timestamp + COOLDOWN);
        // when the bond pays out, the token calls back into withdraw() as the bond itself (msg.sender = token
        // is not a controller, but nonReentrant must trip first)
        t.setHook(address(b), abi.encodeCall(AgentBond.withdraw, (k)));
        vm.prank(operator);
        b.withdraw(k);
        assertTrue(t.hookFired());
        assertTrue(t.hookReverted(), "re-entry must fail");
        assertEq(t.balanceOf(operator), 100e6);
        assertEq(b.coverageOf(k).amount, 0);
    }

    function test_reentrancy_resolveClaimPayoutCannotReenter() public {
        HookBlacklistToken t = new HookBlacklistToken();
        AgentBond b = new AgentBond(address(t), address(0), COOLDOWN, TIMEOUT, 0);
        t.mint(operator, 100e6);
        vm.prank(operator);
        t.approve(address(b), type(uint256).max);
        vm.prank(operator);
        b.depositForAccount(operator, arbiter, 100e6);
        bytes32 k = b.keyOfAccount(operator);
        vm.prank(claimant);
        uint256 id = b.fileClaim(k, 60e6, "x");
        t.setHook(address(b), abi.encodeCall(AgentBond.expireClaim, (id)));
        vm.prank(arbiter);
        b.resolveClaim(id, 60e6, 0);
        assertTrue(t.hookReverted());
        assertEq(t.balanceOf(claimant), 60e6);
        assertEq(t.balanceOf(address(b)), 40e6);
    }

    // ---------- non-standard ERC20 (USDT: no return values) ----------

    function test_noReturnToken_fullLifecycle() public {
        NoReturnToken t = new NoReturnToken();
        AgentBond b = new AgentBond(address(t), address(registry), COOLDOWN, TIMEOUT, DEP);
        address[2] memory a = [operator, claimant];
        for (uint256 i; i < 2; i++) {
            t.mint(a[i], 100e6);
            vm.prank(a[i]);
            t.approve(address(b), type(uint256).max);
        }
        vm.prank(operator);
        b.depositForAgent(agentId, arbiter, 50e6);
        bytes32 k = b.keyOfAgent(agentId);
        vm.prank(claimant);
        uint256 id = b.fileClaim(k, 20e6, "x");
        vm.prank(arbiter);
        b.resolveClaim(id, 20e6, 0);
        assertEq(t.balanceOf(claimant), 120e6);
        vm.prank(operator);
        b.requestWithdraw(k, 30e6);
        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(operator);
        b.withdraw(k);
        assertEq(t.balanceOf(address(b)), 0);
        assertEq(t.balanceOf(operator), 50e6 + 30e6);
    }

    // ---------- fuzz ----------

    function testFuzz_depositWithdrawRoundTrip(uint256 amt, uint256 part) public {
        amt = bound(amt, 1, 1_000_000_000e6);
        part = bound(part, 1, amt);
        _dep(amt);
        uint256 before = usdc.balanceOf(operator);
        vm.prank(operator);
        bond.requestWithdraw(key, part);
        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(operator);
        bond.withdraw(key);
        assertEq(usdc.balanceOf(operator), before + part);
        assertEq(bond.coverageOf(key).amount, amt - part);
        assertEq(usdc.balanceOf(address(bond)), amt - part);
    }

    function testFuzz_requestWithdrawAboveBondReverts(uint256 amt, uint256 over) public {
        amt = bound(amt, 1, 1_000_000e6);
        over = bound(over, 1, type(uint128).max);
        _dep(amt);
        vm.prank(operator);
        vm.expectRevert(AgentBond.InvalidAmount.selector);
        bond.requestWithdraw(key, amt + over);
    }

    /// Mixed outcomes never break: balance == bond.amount + held deposits, claimant/bond conservation.
    function testFuzz_claimOutcomesConserveFunds(uint256 bondAmt, uint256 req, uint256 slash, uint8 mode) public {
        bondAmt = bound(bondAmt, 1, 1_000_000e6);
        req = bound(req, 1, 2_000_000e6);
        _dep(bondAmt);
        uint256 id = _file(req);
        assertEq(usdc.balanceOf(address(bond)), bondAmt + DEP);
        assertEq(bond.heldClaimDeposits(), DEP);
        mode = uint8(bound(mode, 0, 2));
        uint256 cBefore = usdc.balanceOf(claimant);
        uint256 total = bondAmt + DEP;
        if (mode == 0) {
            uint256 max = req < bondAmt ? req : bondAmt;
            slash = bound(slash, 0, max);
            vm.prank(arbiter);
            bond.resolveClaim(id, slash, 0);
            assertEq(usdc.balanceOf(claimant), cBefore + slash + (slash == 0 ? 0 : DEP));
        } else if (mode == 1) {
            vm.prank(claimant);
            bond.cancelClaim(id);
            assertEq(usdc.balanceOf(claimant), cBefore);
        } else {
            vm.warp(block.timestamp + TIMEOUT);
            bond.expireClaim(id);
            assertEq(usdc.balanceOf(claimant), cBefore + DEP);
        }
        assertEq(bond.heldClaimDeposits(), 0);
        assertEq(bond.coverageOf(key).openClaims, 0);
        assertEq(usdc.balanceOf(address(bond)), bond.coverageOf(key).amount);
        assertEq(usdc.balanceOf(address(bond)) + usdc.balanceOf(claimant) - cBefore, total);
    }

    function testFuzz_slashAboveLimitsReverts(uint256 bondAmt, uint256 req, uint256 over) public {
        bondAmt = bound(bondAmt, 1, 1_000_000e6);
        req = bound(req, 1, 1_000_000e6);
        over = bound(over, 1, 1_000_000e6);
        _dep(bondAmt);
        uint256 id = _file(req);
        uint256 lim = req < bondAmt ? req : bondAmt;
        vm.prank(arbiter);
        vm.expectRevert();
        bond.resolveClaim(id, lim + over, 0);
    }

    function testFuzz_nonController_cannotDrain(address who, uint256 amt) public {
        vm.assume(who != operator && who != address(0));
        amt = bound(amt, 1, 1_000e6);
        _dep(1_000e6);
        vm.startPrank(who);
        vm.expectRevert(AgentBond.NotController.selector);
        bond.requestWithdraw(key, amt);
        vm.expectRevert(AgentBond.NotController.selector);
        bond.withdraw(key);
        vm.expectRevert(AgentBond.NotOwner.selector);
        bond.setArbiter(key, who);
        vm.expectRevert(AgentBond.UnknownClaim.selector);
        bond.resolveClaim(1, amt, 0);
        vm.stopPrank();
    }
}
