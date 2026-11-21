// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal ERC-8004 Identity Registry surface used by Agentbond.
///         The live registry is an ERC-721; `ownerOf` is the source of truth for an agent id.
///         `getAgentWallet` is optional and is probed with a staticcall so a missing
///         selector does not revert.
interface IIdentityRegistry {
    function ownerOf(uint256 agentId) external view returns (address);
    function tokenURI(uint256 agentId) external view returns (string memory);
    function getAgentWallet(uint256 agentId) external view returns (address);
}
