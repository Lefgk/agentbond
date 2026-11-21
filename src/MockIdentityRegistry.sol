// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Local-only ERC-8004-shaped registry. Never deploy to mainnet.
contract MockIdentityRegistry {
    uint256 public nextId = 1;
    mapping(uint256 => address) internal _ownerOf;
    mapping(uint256 => string) internal _tokenURI;
    mapping(uint256 => address) internal _agentWallet;

    error NotMinted();
    error NotOwner();

    event Registered(uint256 indexed agentId, address indexed owner, string uri);

    function register(address owner, string calldata uri) external returns (uint256 id) {
        require(owner != address(0), "owner=0");
        id = nextId++;
        _ownerOf[id] = owner;
        _tokenURI[id] = uri;
        _agentWallet[id] = owner;
        emit Registered(id, owner, uri);
    }

    function ownerOf(uint256 agentId) external view returns (address) {
        address o = _ownerOf[agentId];
        if (o == address(0)) revert NotMinted();
        return o;
    }

    function tokenURI(uint256 agentId) external view returns (string memory) {
        if (_ownerOf[agentId] == address(0)) revert NotMinted();
        return _tokenURI[agentId];
    }

    function getAgentWallet(uint256 agentId) external view returns (address) {
        if (_ownerOf[agentId] == address(0)) revert NotMinted();
        return _agentWallet[agentId];
    }

    function setAgentWallet(uint256 agentId, address wallet) external {
        if (msg.sender != _ownerOf[agentId]) revert NotOwner();
        _agentWallet[agentId] = wallet;
    }

    function transfer(uint256 agentId, address to) external {
        if (msg.sender != _ownerOf[agentId]) revert NotOwner();
        require(to != address(0), "to=0");
        _ownerOf[agentId] = to;
        // Match ERC-8004: the wallet is cleared on transfer until the new owner re-verifies.
        _agentWallet[agentId] = address(0);
    }
}
