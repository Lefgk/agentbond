// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IIdentityRegistry} from "./interfaces/IIdentityRegistry.sol";

/// @title Agentbond
/// @notice USDC surety bonds keyed to an ERC-8004 agent id (or a plain address fallback).
///         An operator posts coverage, names an arbiter, and claimants file evidence-backed
///         claims. The arbiter may slash up to the remaining bond to the claimant.
///         Withdrawals have a cooldown and are blocked while claims are open.
/// @dev Prototype, not audited. USDC-only. No protocol fee and no admin in v1.
contract AgentBond is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --- types ---

    enum Kind {
        None,
        AgentId,
        Account
    }

    enum ClaimStatus {
        None,
        Pending,
        Slashed,
        Rejected,
        Cancelled,
        Expired
    }

    struct Bond {
        Kind kind;
        uint256 agentId;
        address account;
        address arbiter;
        uint256 amount;
        uint256 totalDeposited;
        uint256 totalSlashed;
        uint256 pendingWithdraw;
        uint64 withdrawAvailableAt;
        uint32 openClaims;
        uint32 slashCount;
    }

    struct Coverage {
        Kind kind;
        uint256 agentId;
        address account;
        address arbiter;
        address operator;
        uint256 amount;
        uint256 totalDeposited;
        uint256 totalSlashed;
        uint256 pendingWithdraw;
        uint64 withdrawAvailableAt;
        uint32 openClaims;
        uint32 slashCount;
    }

    struct Claim {
        bytes32 bondKey;
        address claimant;
        uint256 requested;
        uint256 slashed;
        string evidenceURI;
        bytes32 reasonHash;
        ClaimStatus status;
        uint64 filedAt;
    }

    struct SlashRecord {
        uint256 claimId;
        address claimant;
        uint256 amount;
        bytes32 reasonHash;
        uint64 timestamp;
    }

    // --- immutables ---

    IERC20 public immutable usdc;
    address public immutable identityRegistry; // address(0) = address-keyed bonds only
    uint64 public immutable withdrawCooldown;
    uint64 public immutable claimTimeout;
    uint256 public constant MAX_URI_LENGTH = 512;

    // --- state ---

    mapping(bytes32 => Bond) internal _bonds;
    mapping(bytes32 => SlashRecord[]) internal _slashes;
    mapping(bytes32 => uint256[]) internal _claimIds;
    mapping(uint256 => Claim) internal _claims;
    uint256 public claimCount;

    // --- errors ---

    error ZeroAddress();
    error ZeroAmount();
    error InvalidAgentId();
    error InvalidEvidence();
    error InvalidAmount();
    error RegistryNotSet();
    error UnknownAgent();
    error UnknownBond();
    error UnknownClaim();
    error ArbiterMismatch();
    error NotController();
    error NotArbiter();
    error NotClaimant();
    error NotPending();
    error OpenClaims();
    error NoPendingWithdraw();
    error CooldownActive();
    error ClaimNotExpired();
    error EmptyBond();
    error ExceedsRequested(uint256 slashAmount, uint256 requested);
    error ExceedsBond(uint256 slashAmount, uint256 remaining);
    error ControllerCannotClaim();
    error ArbiterCannotClaim();

    // --- events ---

    event BondDeposited(bytes32 indexed bondKey, address indexed from, uint256 amount, uint256 newCoverage);
    event ArbiterSet(bytes32 indexed bondKey, address indexed oldArbiter, address indexed newArbiter);
    event WithdrawRequested(bytes32 indexed bondKey, uint256 amount, uint64 availableAt);
    event WithdrawCancelled(bytes32 indexed bondKey);
    event Withdrawn(bytes32 indexed bondKey, address indexed to, uint256 amount);
    event ClaimFiled(
        uint256 indexed claimId, bytes32 indexed bondKey, address indexed claimant, uint256 requested, string evidenceURI
    );
    event ClaimResolved(
        uint256 indexed claimId, bytes32 indexed bondKey, uint256 slashAmount, bytes32 reasonHash, ClaimStatus status
    );
    event ClaimCancelled(uint256 indexed claimId, bytes32 indexed bondKey);
    event ClaimExpired(uint256 indexed claimId, bytes32 indexed bondKey);
    event Slashed(
        bytes32 indexed bondKey, uint256 indexed claimId, address indexed claimant, uint256 amount, bytes32 reasonHash
    );

    constructor(address usdc_, address identityRegistry_, uint64 withdrawCooldown_, uint64 claimTimeout_) {
        if (usdc_ == address(0)) revert ZeroAddress();
        if (withdrawCooldown_ == 0 || claimTimeout_ == 0) revert InvalidAmount();
        usdc = IERC20(usdc_);
        identityRegistry = identityRegistry_;
        withdrawCooldown = withdrawCooldown_;
        claimTimeout = claimTimeout_;
    }

    // --- keys ---

    function keyOfAgent(uint256 agentId) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(uint8(1), agentId));
    }

    function keyOfAccount(address account) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(uint8(2), account));
    }

    // --- deposits ---

    /// @notice Post or top up a bond for a live ERC-8004 agent id. First deposit names the arbiter.
    ///         Anyone may top up; only the current 8004 owner (or agent wallet) can withdraw.
    function depositForAgent(uint256 agentId, address arbiter, uint256 amount) external nonReentrant {
        if (identityRegistry == address(0)) revert RegistryNotSet();
        if (agentId == 0) revert InvalidAgentId();
        _requireAgent(agentId);
        _deposit(keyOfAgent(agentId), Kind.AgentId, agentId, address(0), arbiter, amount);
    }

    /// @notice Post or top up a bond keyed to a plain address (fallback when no 8004 id is used).
    function depositForAccount(address account, address arbiter, uint256 amount) external nonReentrant {
        if (account == address(0)) revert ZeroAddress();
        _deposit(keyOfAccount(account), Kind.Account, 0, account, arbiter, amount);
    }

    // --- arbiter ---

    function setArbiter(bytes32 key, address newArbiter) external {
        Bond storage b = _needBond(key);
        if (!_isController(b, msg.sender)) revert NotController();
        if (b.openClaims != 0) revert OpenClaims();
        if (newArbiter == address(0)) revert ZeroAddress();
        address old = b.arbiter;
        b.arbiter = newArbiter;
        emit ArbiterSet(key, old, newArbiter);
    }

    // --- withdrawals ---

    /// @notice Start a cooldown. Blocked while claims are open. Does not lock funds from slashes.
    function requestWithdraw(bytes32 key, uint256 amount) external {
        Bond storage b = _needBond(key);
        if (!_isController(b, msg.sender)) revert NotController();
        if (b.openClaims != 0) revert OpenClaims();
        if (amount == 0 || amount > b.amount) revert InvalidAmount();
        b.pendingWithdraw = amount;
        b.withdrawAvailableAt = uint64(block.timestamp) + withdrawCooldown;
        emit WithdrawRequested(key, amount, b.withdrawAvailableAt);
    }

    function cancelWithdraw(bytes32 key) external {
        Bond storage b = _needBond(key);
        if (!_isController(b, msg.sender)) revert NotController();
        if (b.withdrawAvailableAt == 0) revert NoPendingWithdraw();
        b.pendingWithdraw = 0;
        b.withdrawAvailableAt = 0;
        emit WithdrawCancelled(key);
    }

    /// @notice Finalize a withdraw after the cooldown, if no claims are open.
    ///         Pays the current operator. If a slash reduced coverage, pays the remaining amount.
    function withdraw(bytes32 key) external nonReentrant {
        Bond storage b = _needBond(key);
        if (!_isController(b, msg.sender)) revert NotController();
        if (b.openClaims != 0) revert OpenClaims();
        if (b.withdrawAvailableAt == 0) revert NoPendingWithdraw();
        if (block.timestamp < b.withdrawAvailableAt) revert CooldownActive();
        uint256 amt = b.pendingWithdraw;
        if (amt > b.amount) amt = b.amount;
        if (amt == 0) revert ZeroAmount();
        b.amount -= amt;
        b.pendingWithdraw = 0;
        b.withdrawAvailableAt = 0;
        address to = _operator(b);
        usdc.safeTransfer(to, amt);
        emit Withdrawn(key, to, amt);
    }

    // --- claims and slashing ---

    function fileClaim(bytes32 key, uint256 amount, string calldata evidenceURI) external returns (uint256 claimId) {
        Bond storage b = _needBond(key);
        if (b.amount == 0) revert EmptyBond();
        if (amount == 0) revert ZeroAmount();
        uint256 uriLen = bytes(evidenceURI).length;
        if (uriLen == 0 || uriLen > MAX_URI_LENGTH) revert InvalidEvidence();
        if (msg.sender == b.arbiter) revert ArbiterCannotClaim();
        if (_isController(b, msg.sender)) revert ControllerCannotClaim();

        claimId = ++claimCount;
        _claims[claimId] = Claim({
            bondKey: key,
            claimant: msg.sender,
            requested: amount,
            slashed: 0,
            evidenceURI: evidenceURI,
            reasonHash: bytes32(0),
            status: ClaimStatus.Pending,
            filedAt: uint64(block.timestamp)
        });
        _claimIds[key].push(claimId);
        b.openClaims += 1;
        emit ClaimFiled(claimId, key, msg.sender, amount, evidenceURI);
    }

    /// @notice Arbiter-only. `slashAmount == 0` rejects the claim. Otherwise pays the claimant
    ///         `slashAmount`, which cannot exceed the requested amount or the remaining bond.
    function resolveClaim(uint256 claimId, uint256 slashAmount, bytes32 reasonHash) external nonReentrant {
        Claim storage c = _needPending(claimId);
        Bond storage b = _bonds[c.bondKey];
        if (msg.sender != b.arbiter) revert NotArbiter();
        if (slashAmount > c.requested) revert ExceedsRequested(slashAmount, c.requested);
        if (slashAmount > b.amount) revert ExceedsBond(slashAmount, b.amount);

        b.openClaims -= 1;
        c.slashed = slashAmount;
        c.reasonHash = reasonHash;

        if (slashAmount == 0) {
            c.status = ClaimStatus.Rejected;
        } else {
            c.status = ClaimStatus.Slashed;
            b.amount -= slashAmount;
            b.totalSlashed += slashAmount;
            b.slashCount += 1;
            _slashes[c.bondKey].push(
                SlashRecord({
                    claimId: claimId,
                    claimant: c.claimant,
                    amount: slashAmount,
                    reasonHash: reasonHash,
                    timestamp: uint64(block.timestamp)
                })
            );
            usdc.safeTransfer(c.claimant, slashAmount);
            emit Slashed(c.bondKey, claimId, c.claimant, slashAmount, reasonHash);
        }
        emit ClaimResolved(claimId, c.bondKey, slashAmount, reasonHash, c.status);
    }

    function cancelClaim(uint256 claimId) external {
        Claim storage c = _needPending(claimId);
        if (msg.sender != c.claimant) revert NotClaimant();
        _bonds[c.bondKey].openClaims -= 1;
        c.status = ClaimStatus.Cancelled;
        emit ClaimCancelled(claimId, c.bondKey);
    }

    /// @notice Anyone may expire a pending claim after `claimTimeout`, unblocking withdrawals.
    function expireClaim(uint256 claimId) external {
        Claim storage c = _needPending(claimId);
        if (block.timestamp < uint256(c.filedAt) + claimTimeout) revert ClaimNotExpired();
        _bonds[c.bondKey].openClaims -= 1;
        c.status = ClaimStatus.Expired;
        emit ClaimExpired(claimId, c.bondKey);
    }

    // --- views ---

    function coverageOf(bytes32 key) public view returns (Coverage memory) {
        Bond storage b = _bonds[key];
        return Coverage({
            kind: b.kind,
            agentId: b.agentId,
            account: b.account,
            arbiter: b.arbiter,
            operator: b.arbiter == address(0) ? address(0) : _operatorOrZero(b),
            amount: b.amount,
            totalDeposited: b.totalDeposited,
            totalSlashed: b.totalSlashed,
            pendingWithdraw: b.pendingWithdraw,
            withdrawAvailableAt: b.withdrawAvailableAt,
            openClaims: b.openClaims,
            slashCount: b.slashCount
        });
    }

    function coverageOfAgent(uint256 agentId) external view returns (Coverage memory) {
        return coverageOf(keyOfAgent(agentId));
    }

    function coverageOfAccount(address account) external view returns (Coverage memory) {
        return coverageOf(keyOfAccount(account));
    }

    function getBond(bytes32 key) external view returns (Bond memory) {
        return _bonds[key];
    }

    function getClaim(uint256 claimId) external view returns (Claim memory) {
        return _claims[claimId];
    }

    function claimIds(bytes32 key) external view returns (uint256[] memory) {
        return _claimIds[key];
    }

    function slashHistory(bytes32 key) external view returns (SlashRecord[] memory) {
        return _slashes[key];
    }

    function slashHistoryOfAgent(uint256 agentId) external view returns (SlashRecord[] memory) {
        return _slashes[keyOfAgent(agentId)];
    }

    function slashHistoryOfAccount(address account) external view returns (SlashRecord[] memory) {
        return _slashes[keyOfAccount(account)];
    }

    function isController(bytes32 key, address who) external view returns (bool) {
        Bond storage b = _bonds[key];
        if (b.arbiter == address(0)) return false;
        return _isController(b, who);
    }

    function agentOwner(uint256 agentId) external view returns (address) {
        return IIdentityRegistry(identityRegistry).ownerOf(agentId);
    }

    function agentWallet(uint256 agentId) external view returns (address) {
        return _tryAgentWallet(agentId);
    }

    // --- internals ---

    function _deposit(
        bytes32 key,
        Kind kind,
        uint256 agentId,
        address account,
        address arbiter,
        uint256 amount
    ) internal {
        if (amount == 0) revert ZeroAmount();
        Bond storage b = _bonds[key];
        if (b.arbiter == address(0)) {
            if (arbiter == address(0)) revert ZeroAddress();
            b.kind = kind;
            b.agentId = agentId;
            b.account = account;
            b.arbiter = arbiter;
            emit ArbiterSet(key, address(0), arbiter);
        } else if (arbiter != address(0) && arbiter != b.arbiter) {
            revert ArbiterMismatch();
        }
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        b.amount += amount;
        b.totalDeposited += amount;
        emit BondDeposited(key, msg.sender, amount, b.amount);
    }

    function _needBond(bytes32 key) internal view returns (Bond storage b) {
        b = _bonds[key];
        if (b.arbiter == address(0)) revert UnknownBond();
    }

    function _needPending(uint256 claimId) internal view returns (Claim storage c) {
        c = _claims[claimId];
        if (c.status == ClaimStatus.None) revert UnknownClaim();
        if (c.status != ClaimStatus.Pending) revert NotPending();
    }

    function _requireAgent(uint256 agentId) internal view {
        try IIdentityRegistry(identityRegistry).ownerOf(agentId) returns (address owner) {
            if (owner == address(0)) revert UnknownAgent();
        } catch {
            revert UnknownAgent();
        }
    }

    function _operator(Bond storage b) internal view returns (address) {
        if (b.kind == Kind.Account) return b.account;
        return IIdentityRegistry(identityRegistry).ownerOf(b.agentId);
    }

    function _operatorOrZero(Bond storage b) internal view returns (address) {
        if (b.kind == Kind.Account) return b.account;
        try IIdentityRegistry(identityRegistry).ownerOf(b.agentId) returns (address owner) {
            return owner;
        } catch {
            return address(0);
        }
    }

    function _isController(Bond storage b, address who) internal view returns (bool) {
        if (b.kind == Kind.Account) return who == b.account;
        try IIdentityRegistry(identityRegistry).ownerOf(b.agentId) returns (address owner) {
            if (who == owner) return true;
        } catch {
            return false;
        }
        address wallet = _tryAgentWallet(b.agentId);
        return wallet != address(0) && who == wallet;
    }

    function _tryAgentWallet(uint256 agentId) internal view returns (address) {
        if (identityRegistry == address(0)) return address(0);
        (bool ok, bytes memory data) =
            identityRegistry.staticcall(abi.encodeWithSelector(IIdentityRegistry.getAgentWallet.selector, agentId));
        if (!ok || data.length < 32) return address(0);
        return abi.decode(data, (address));
    }
}
