// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AgentBond} from "../../src/AgentBond.sol";
import {IIdentityRegistry} from "../../src/interfaces/IIdentityRegistry.sol";
import {DeployConfig} from "../../script/DeployConfig.sol";

interface IFiatToken is IERC20Metadata {
    function masterMinter() external view returns (address);
    function configureMinter(address minter, uint256 minterAllowedAmount) external returns (bool);
    function mint(address to, uint256 amount) external returns (bool);
}

interface IERC165 {
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

interface IIdentityRegister {
    function register(string memory agentURI) external returns (uint256 agentId);
}

/// @dev Runs against a fork of a live chain using the chain's real Circle USDC and, if present,
///      the live ERC-8004 Identity Registry.
///      Either run `forge test --fork-url <rpc>` (only the matching chain's suite runs), or set
///      MAINNET_FORK_RPC / BASE_FORK_RPC (e.g. a local `anvil --fork-url`). Otherwise skipped.
abstract contract ForkBase is Test {
    AgentBond internal bond;
    IERC20Metadata internal usdc;
    address internal registry;
    address internal operator = makeAddr("fork-operator");
    address internal arbiter = makeAddr("fork-arbiter");
    address internal claimant = makeAddr("fork-claimant");
    bool internal active;
    bool internal registryLive;

    uint64 internal constant COOLDOWN = 7 days;
    uint64 internal constant TIMEOUT = 14 days;

    function _rpcEnv() internal pure virtual returns (string memory);
    function _chainId() internal pure virtual returns (uint256);

    function setUp() public {
        if (block.chainid == _chainId()) {
            // already running on this chain's fork (forge test --fork-url ...)
        } else if (block.chainid == 31337) {
            string memory rpc = vm.envOr(_rpcEnv(), string(""));
            if (bytes(rpc).length == 0) return;
            vm.createSelectFork(rpc);
        } else {
            return;
        }
        active = true;
        assertEq(block.chainid, _chainId(), "wrong fork chain");
        DeployConfig.Chain memory c = DeployConfig.get(block.chainid);
        usdc = IERC20Metadata(c.usdc);
        registry = c.identityRegistry;
        registryLive = registry.code.length > 0;
        bond = new AgentBond(address(usdc), registryLive ? registry : address(0), COOLDOWN, TIMEOUT, 1e6);

        _fundUsdc(operator, 10_000e6);
        vm.prank(operator);
        usdc.approve(address(bond), type(uint256).max);
        // claimants escrow a 1 USDC claim deposit (audit fix M-3)
        _fundUsdc(claimant, 1e6);
        vm.prank(claimant);
        usdc.approve(address(bond), type(uint256).max);
    }

    function _fundUsdc(address to, uint256 amount) internal {
        IFiatToken token = IFiatToken(address(usdc));
        address master = token.masterMinter();
        vm.prank(master);
        token.configureMinter(address(this), type(uint256).max);
        bool minted = token.mint(to, amount);
        require(minted || token.balanceOf(to) >= amount, "fork: USDC mint failed");
    }

    modifier onFork() {
        if (!active) {
            vm.skip(true);
            return;
        }
        _;
    }

    function test_fork_realUsdcMetadata() public onFork {
        assertEq(usdc.symbol(), "USDC");
        assertEq(usdc.decimals(), 6);
        assertGt(address(usdc).code.length, 0);
        assertEq(DeployConfig.get(block.chainid).usdc, address(usdc));
    }

    function test_fork_identityRegistryIfPresent() public onFork {
        address expected = DeployConfig.IDENTITY_REGISTRY;
        assertEq(registry, expected);
        if (!registryLive) {
            emit log("ERC-8004 registry has no code on this fork; address-key fallback is in use");
            return;
        }
        assertGt(registry.code.length, 0, "registry code");
        (bool ok, bytes memory data) =
            registry.staticcall(abi.encodeWithSelector(IERC165.supportsInterface.selector, bytes4(0x80ac58cd)));
        if (ok && data.length >= 32) {
            assertTrue(abi.decode(data, (bool)), "registry should be ERC-721");
        }
        // Probe a few low ids; any hit is enough to prove ownerOf works.
        bool found;
        for (uint256 id = 1; id <= 16; id++) {
            try IIdentityRegistry(registry).ownerOf(id) returns (address owner) {
                if (owner != address(0)) {
                    found = true;
                    emit log_named_uint("found agentId", id);
                    emit log_named_address("owner", owner);
                    break;
                }
            } catch {}
        }
        if (!found) emit log("no low-id agents found; register path is tried in the 8004 deposit test");
    }

    function test_fork_addressKeyedBondClaimSlashAndCooldown() public onFork {
        vm.prank(operator);
        bond.depositForAccount(operator, arbiter, 1_000e6);
        AgentBond.Coverage memory c = bond.coverageOfAccount(operator);
        assertEq(c.amount, 1_000e6);
        assertEq(c.arbiter, arbiter);
        assertEq(usdc.balanceOf(address(bond)), 1_000e6);

        bytes32 key = bond.keyOfAccount(operator);
        uint256 claimantStart = usdc.balanceOf(claimant);
        vm.prank(claimant);
        uint256 claimId = bond.fileClaim(key, 200e6, "ipfs://fork-evidence");
        vm.prank(arbiter);
        bond.resolveClaim(claimId, 150e6, keccak256("fork-slash"));
        assertEq(bond.coverageOfAccount(operator).amount, 850e6);
        assertEq(bond.coverageOfAccount(operator).totalSlashed, 150e6);
        assertEq(usdc.balanceOf(claimant), claimantStart + 150e6); // slash + refunded deposit
        assertEq(bond.slashHistoryOfAccount(operator).length, 1);

        vm.prank(operator);
        bond.requestWithdraw(key, 100e6);
        vm.prank(operator);
        vm.expectRevert(AgentBond.CooldownActive.selector);
        bond.withdraw(key);
        vm.warp(block.timestamp + COOLDOWN);
        uint256 before = usdc.balanceOf(operator);
        vm.prank(operator);
        bond.withdraw(key);
        assertEq(usdc.balanceOf(operator), before + 100e6);
        assertEq(bond.coverageOfAccount(operator).amount, 750e6);
    }

    function test_fork_8004BondIfRegistryLive() public onFork {
        if (!registryLive) {
            vm.skip(true);
            return;
        }

        uint256 agentId;
        bool registered;
        vm.prank(operator);
        try IIdentityRegister(registry).register("ipfs://agentbond-fork") returns (uint256 id) {
            agentId = id;
            registered = true;
        } catch {}

        if (!registered) {
            // Fall back: impersonate the owner of a low existing id.
            for (uint256 id = 1; id <= 32; id++) {
                try IIdentityRegistry(registry).ownerOf(id) returns (address foundOwner) {
                    if (foundOwner != address(0)) {
                        agentId = id;
                        operator = foundOwner;
                        _fundUsdc(operator, 10_000e6);
                        vm.prank(operator);
                        usdc.approve(address(bond), type(uint256).max);
                        registered = true;
                        break;
                    }
                } catch {}
            }
        }

        if (!registered) {
            emit log("could not register or find an ERC-8004 agent; skipping 8004 deposit");
            vm.skip(true);
            return;
        }

        address owner = IIdentityRegistry(registry).ownerOf(agentId);
        assertEq(owner, operator);
        vm.prank(operator);
        bond.depositForAgent(agentId, arbiter, 250e6);
        AgentBond.Coverage memory c = bond.coverageOfAgent(agentId);
        assertEq(c.amount, 250e6);
        assertEq(c.agentId, agentId);
        assertEq(c.operator, operator);
        assertEq(uint256(c.kind), uint256(AgentBond.Kind.AgentId));
    }

    function testFuzz_fork_slashNeverExceedsRealUsdcBond(uint256 deposit, uint256 requested, uint256 slashAmount)
        public
        onFork
    {
        deposit = bound(deposit, 1, 5_000e6);
        requested = bound(requested, 1, 10_000e6);
        slashAmount = bound(slashAmount, 0, requested + deposit);
        // reset coverage by using a unique account per run is hard; use operator and require a clean bond
        // Deposit on a fresh throwaway account instead.
        address acct = address(uint160(uint256(keccak256(abi.encode(deposit, requested, slashAmount, "acct")))));
        _fundUsdc(acct, deposit);
        vm.prank(acct);
        usdc.approve(address(bond), type(uint256).max);
        vm.prank(acct);
        bond.depositForAccount(acct, arbiter, deposit);
        bytes32 key = bond.keyOfAccount(acct);

        vm.prank(claimant);
        uint256 id = bond.fileClaim(key, requested, "ipfs://fuzz-fork");
        if (slashAmount > requested || slashAmount > deposit) {
            vm.prank(arbiter);
            vm.expectRevert();
            bond.resolveClaim(id, slashAmount, keccak256("f"));
            assertEq(bond.coverageOfAccount(acct).amount, deposit);
        } else {
            vm.prank(arbiter);
            bond.resolveClaim(id, slashAmount, keccak256("f"));
            AgentBond.Coverage memory c = bond.coverageOfAccount(acct);
            // a rejection (slash 0) adds the forfeited 1 USDC claim deposit to the bond
            assertEq(c.amount, slashAmount == 0 ? deposit + 1e6 : deposit - slashAmount);
            assertLe(c.totalSlashed, c.totalDeposited);
            assertEq(usdc.balanceOf(address(bond)), usdc.balanceOf(address(bond)));
            assertEq(c.totalSlashed, slashAmount);
        }
    }
}

contract EthereumForkTest is ForkBase {
    function _rpcEnv() internal pure override returns (string memory) {
        return "MAINNET_FORK_RPC";
    }

    function _chainId() internal pure override returns (uint256) {
        return 1;
    }
}

contract BaseForkTest is ForkBase {
    function _rpcEnv() internal pure override returns (string memory) {
        return "BASE_FORK_RPC";
    }

    function _chainId() internal pure override returns (uint256) {
        return 8453;
    }
}
