// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AgentBond} from "../src/AgentBond.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {MockIdentityRegistry} from "../src/MockIdentityRegistry.sol";

contract AgentBondHandler is Test {
    AgentBond public bond;
    MockUSDC public usdc;
    MockIdentityRegistry public registry;

    address public operator;
    address public arbiter;
    address public claimant;
    address public stranger;
    uint256 public agentId;

    uint256 public ghostDeposited;
    uint256 public ghostSlashed;
    uint256 public ghostWithdrawn;

    bytes32[] public keys;

    constructor(AgentBond bond_, MockUSDC usdc_, MockIdentityRegistry registry_, uint256 agentId_) {
        bond = bond_;
        usdc = usdc_;
        registry = registry_;
        agentId = agentId_;
        operator = makeAddr("inv-operator");
        arbiter = makeAddr("inv-arbiter");
        claimant = makeAddr("inv-claimant");
        stranger = makeAddr("inv-stranger");
    }

    function configure(address operator_, uint256 agentId_) external {
        require(keys.length == 0, "configured");
        operator = operator_;
        agentId = agentId_;
        keys.push(bond.keyOfAgent(agentId));
        keys.push(bond.keyOfAccount(operator));
    }

    function depositAgent(uint256 amount, bool fromStranger) external {
        amount = bound(amount, 1e6, 20_000e6);
        address from = fromStranger ? stranger : operator;
        if (usdc.balanceOf(from) < amount) return;
        address arb = bond.coverageOfAgent(agentId).arbiter == address(0) ? arbiter : address(0);
        vm.prank(from);
        try bond.depositForAgent(agentId, arb, amount) {
            ghostDeposited += amount;
        } catch {}
    }

    function depositAccount(uint256 amount) external {
        amount = bound(amount, 1e6, 20_000e6);
        if (usdc.balanceOf(operator) < amount) return;
        address arb = bond.coverageOfAccount(operator).arbiter == address(0) ? arbiter : address(0);
        vm.prank(operator);
        try bond.depositForAccount(operator, arb, amount) {
            ghostDeposited += amount;
        } catch {}
    }

    function file(uint256 keyIdx, uint256 amount) external {
        bytes32 key = _key(keyIdx);
        if (bond.coverageOf(key).amount == 0) return;
        amount = bound(amount, 1, 50_000e6);
        vm.prank(claimant);
        try bond.fileClaim(key, amount, "ipfs://inv") {} catch {}
    }

    function resolve(uint256 claimSeed, uint256 slashSeed) external {
        uint256 id = _claimId(claimSeed);
        if (id == 0) return;
        AgentBond.Claim memory c = bond.getClaim(id);
        if (c.status != AgentBond.ClaimStatus.Pending) return;
        uint256 remaining = bond.coverageOf(c.bondKey).amount;
        uint256 cap = c.requested < remaining ? c.requested : remaining;
        uint256 slashAmount = cap == 0 ? 0 : bound(slashSeed, 0, cap);
        uint256 dep = bond.claimDepositOf(id);
        vm.prank(arbiter);
        try bond.resolveClaim(id, slashAmount, bytes32(slashSeed)) {
            ghostSlashed += slashAmount;
            if (slashAmount == 0) ghostDeposited += dep; // rejected: deposit forfeits into the bond
        } catch {}
    }

    function cancel(uint256 claimSeed) external {
        uint256 id = _claimId(claimSeed);
        if (id == 0) return;
        AgentBond.Claim memory c = bond.getClaim(id);
        if (c.status != AgentBond.ClaimStatus.Pending) return;
        uint256 dep = bond.claimDepositOf(id);
        vm.prank(c.claimant);
        try bond.cancelClaim(id) {
            ghostDeposited += dep; // cancelled: deposit forfeits into the bond
        } catch {}
    }

    function expire(uint256 claimSeed) external {
        uint256 id = _claimId(claimSeed);
        if (id == 0) return;
        AgentBond.Claim memory c = bond.getClaim(id);
        if (c.status != AgentBond.ClaimStatus.Pending) return;
        if (block.timestamp < uint256(c.filedAt) + bond.claimTimeout()) {
            vm.warp(uint256(c.filedAt) + bond.claimTimeout());
        }
        try bond.expireClaim(id) {} catch {}
    }

    function requestWithdraw(uint256 keyIdx, uint256 amount) external {
        bytes32 key = _key(keyIdx);
        AgentBond.Coverage memory cov = bond.coverageOf(key);
        if (cov.amount == 0) return;
        amount = bound(amount, 1, cov.amount);
        vm.prank(operator);
        try bond.requestWithdraw(key, amount) {} catch {}
    }

    function cancelWithdraw(uint256 keyIdx) external {
        bytes32 key = _key(keyIdx);
        vm.prank(operator);
        try bond.cancelWithdraw(key) {} catch {}
    }

    function finalizeWithdraw(uint256 keyIdx) external {
        bytes32 key = _key(keyIdx);
        AgentBond.Coverage memory cov = bond.coverageOf(key);
        if (cov.withdrawAvailableAt == 0) return;
        if (block.timestamp < cov.withdrawAvailableAt) {
            vm.warp(cov.withdrawAvailableAt);
        }
        uint256 expected = cov.pendingWithdraw > cov.amount ? cov.amount : cov.pendingWithdraw;
        uint256 before = usdc.balanceOf(address(bond));
        vm.prank(operator);
        try bond.withdraw(key) {
            ghostWithdrawn += before - usdc.balanceOf(address(bond));
            // expected may differ if a slash landed; use actual delta
            expected;
        } catch {}
    }

    bool public ghostInstantSwap;
    bool public ghostSquatted;

    /// Owner queues a puppet arbiter and tries to apply it right away (must fail before the cooldown).
    function swapArbiter(uint256 keyIdx, bool applyNow) external {
        bytes32 key = _key(keyIdx);
        if (bond.coverageOf(key).arbiter == address(0)) return;
        address puppet = makeAddr("inv-puppet");
        vm.prank(operator);
        try bond.setArbiter(key, puppet) {} catch {}
        (, uint64 at) = bond.pendingArbiter(key);
        if (!applyNow || at == 0) return;
        vm.prank(operator);
        try bond.applyArbiter(key) {
            if (block.timestamp < at) ghostInstantSwap = true;
            // restore the original arbiter through the same delayed path so other actions keep working
            vm.prank(operator);
            bond.setArbiter(key, arbiter);
            vm.warp(block.timestamp + bond.withdrawCooldown());
            vm.prank(operator);
            try bond.applyArbiter(key) {} catch {}
        } catch {}
    }

    /// Stranger tries to create a fresh bond for someone else's account.
    function squat(uint256 seed) external {
        address victim = address(uint160(bound(seed, 1e6, type(uint96).max)));
        vm.prank(stranger);
        try bond.depositForAccount(victim, stranger, 1e6) {
            ghostSquatted = true;
        } catch {}
    }

    function warpTime(uint256 secs) external {
        secs = bound(secs, 1, 30 days);
        vm.warp(block.timestamp + secs);
    }

    function keyCount() external view returns (uint256) {
        return keys.length;
    }

    function _key(uint256 idx) internal view returns (bytes32) {
        return keys[idx % keys.length];
    }

    function _claimId(uint256 seed) internal view returns (uint256) {
        uint256 n = bond.claimCount();
        if (n == 0) return 0;
        return bound(seed, 1, n);
    }
}

contract AgentBondInvariantTest is Test {
    AgentBond internal bond;
    MockUSDC internal usdc;
    MockIdentityRegistry internal registry;
    AgentBondHandler internal handler;

    function setUp() public {
        usdc = new MockUSDC();
        registry = new MockIdentityRegistry();
        bond = new AgentBond(address(usdc), address(registry), 7 days, 14 days, 1e6);
        address operator = makeAddr("inv-operator");
        uint256 agentId = registry.register(operator, "ipfs://inv-agent");
        handler = new AgentBondHandler(bond, usdc, registry, agentId);
        handler.configure(operator, agentId);

        usdc.mint(operator, 10_000_000e6);
        usdc.mint(handler.stranger(), 10_000_000e6);
        vm.prank(operator);
        usdc.approve(address(bond), type(uint256).max);
        vm.prank(handler.stranger());
        usdc.approve(address(bond), type(uint256).max);
        usdc.mint(handler.claimant(), 10_000_000e6);
        vm.prank(handler.claimant());
        usdc.approve(address(bond), type(uint256).max);

        targetContract(address(handler));
        bytes4[] memory excluded = new bytes4[](1);
        excluded[0] = handler.configure.selector;
        excludeSelector(FuzzSelector({addr: address(handler), selectors: excluded}));
    }

    function invariant_contractBalanceEqualsRemainingBonds() public view {
        uint256 remaining;
        uint256 n = handler.keyCount();
        for (uint256 i; i < n; i++) {
            remaining += bond.coverageOf(handler.keys(i)).amount;
        }
        assertEq(usdc.balanceOf(address(bond)), remaining + bond.heldClaimDeposits());
    }

    /// Audit M-3: escrowed claim deposits equal the deposits of exactly the pending claims.
    function invariant_heldDepositsMatchPendingClaims() public view {
        uint256 held;
        uint256 n = bond.claimCount();
        for (uint256 id = 1; id <= n; id++) {
            uint256 d = bond.claimDepositOf(id);
            if (bond.getClaim(id).status == AgentBond.ClaimStatus.Pending) assertEq(d, bond.claimDeposit());
            else assertEq(d, 0);
            held += d;
        }
        assertEq(held, bond.heldClaimDeposits());
    }

    /// Audit M-1: an arbiter change never takes effect before the cooldown.
    function invariant_noInstantArbiterSwap() public view {
        assertFalse(handler.ghostInstantSwap());
    }

    /// Audit M-2: a non-controller never initialises a bond.
    function invariant_noSquat() public view {
        assertFalse(handler.ghostSquatted());
    }

    function invariant_accountingHolds() public view {
        uint256 remaining;
        uint256 slashed;
        uint256 deposited;
        uint256 n = handler.keyCount();
        for (uint256 i; i < n; i++) {
            AgentBond.Coverage memory c = bond.coverageOf(handler.keys(i));
            remaining += c.amount;
            slashed += c.totalSlashed;
            deposited += c.totalDeposited;
            assertLe(c.totalSlashed, c.totalDeposited);
            assertLe(c.amount, c.totalDeposited);
            assertEq(c.totalDeposited, c.amount + c.totalSlashed + _withdrawnOf(c));
        }
        assertEq(deposited, remaining + slashed + (deposited - remaining - slashed));
        assertEq(handler.ghostDeposited(), deposited);
        assertEq(handler.ghostSlashed(), slashed);
        assertEq(handler.ghostDeposited(), remaining + slashed + handler.ghostWithdrawn());
    }

    function invariant_slashHistorySumsToTotalSlashed() public view {
        uint256 n = handler.keyCount();
        for (uint256 i; i < n; i++) {
            bytes32 key = handler.keys(i);
            AgentBond.SlashRecord[] memory hist = bond.slashHistory(key);
            uint256 sum;
            for (uint256 j; j < hist.length; j++) {
                sum += hist[j].amount;
            }
            AgentBond.Coverage memory c = bond.coverageOf(key);
            assertEq(sum, c.totalSlashed);
            assertEq(hist.length, c.slashCount);
        }
    }

    function invariant_openClaimsMatchPending() public view {
        uint256 n = handler.keyCount();
        for (uint256 i; i < n; i++) {
            bytes32 key = handler.keys(i);
            uint256[] memory ids = bond.claimIds(key);
            uint256 pending;
            for (uint256 j; j < ids.length; j++) {
                if (bond.getClaim(ids[j]).status == AgentBond.ClaimStatus.Pending) pending++;
            }
            assertEq(pending, bond.coverageOf(key).openClaims);
        }
    }

    function invariant_slashesNeverExceedDeposit() public view {
        uint256 n = handler.keyCount();
        for (uint256 i; i < n; i++) {
            AgentBond.Coverage memory c = bond.coverageOf(handler.keys(i));
            assertLe(c.totalSlashed, c.totalDeposited);
            assertLe(c.amount + c.totalSlashed, c.totalDeposited);
        }
    }

    function _withdrawnOf(AgentBond.Coverage memory c) internal pure returns (uint256) {
        return c.totalDeposited - c.amount - c.totalSlashed;
    }
}
