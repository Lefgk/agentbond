// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Per-chain deploy settings. Only these chains are supported.
library DeployConfig {
    struct Chain {
        string name;
        bool isMainnet; // live chain with real funds -> needs CONFIRM_MAINNET=yes to broadcast
        address usdc; // Circle native USDC (address(0) on anvil: a MockUSDC is deployed)
        address identityRegistry; // ERC-8004 Identity Registry (address(0) on anvil: a mock is deployed)
    }

    uint256 internal constant ETHEREUM = 1;
    uint256 internal constant BASE = 8453;
    uint256 internal constant ANVIL = 31337;

    address internal constant USDC_ETHEREUM = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    // Deterministic CREATE2 address of the ERC-8004 Identity Registry on Ethereum and Base.
    address internal constant IDENTITY_REGISTRY = 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;

    uint64 internal constant WITHDRAW_COOLDOWN = 7 days;
    uint64 internal constant CLAIM_TIMEOUT = 14 days;

    function get(uint256 chainId) internal pure returns (Chain memory) {
        if (chainId == ETHEREUM) return Chain("Ethereum mainnet", true, USDC_ETHEREUM, IDENTITY_REGISTRY);
        if (chainId == BASE) return Chain("Base", true, USDC_BASE, IDENTITY_REGISTRY);
        if (chainId == ANVIL) return Chain("Local anvil", false, address(0), address(0));
        revert("DeployConfig: unsupported chain (only 1, 8453, 31337)");
    }
}
