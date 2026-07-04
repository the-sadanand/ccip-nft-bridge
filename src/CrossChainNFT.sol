// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title CrossChainNFT
/// @notice ERC-721 token that can be bridged across chains using a burn-and-mint pattern.
///         Minting is strictly restricted to the designated bridge contract so that new
///         tokens can only ever be created as a result of a verified cross-chain message.
contract CrossChainNFT is ERC721URIStorage, Ownable {
    /// @notice Address of the CCIPNFTBridge contract allowed to mint/burn on behalf of users.
    address public bridge;

    event BridgeUpdated(address indexed oldBridge, address indexed newBridge);

    error NotBridge(address caller);
    error ZeroAddress();
    error TokenAlreadyExists(uint256 tokenId);
    error NotOwnerOrApproved(address caller, uint256 tokenId);

    constructor(string memory name, string memory symbol, address initialOwner)
        ERC721(name, symbol)
        Ownable(initialOwner)
    {}

    /// @dev Restricts a function to be callable only by the configured bridge contract.
    modifier onlyBridge() {
        if (msg.sender != bridge) revert NotBridge(msg.sender);
        _;
    }

    /// @notice Sets the address of the bridge contract permitted to mint tokens.
    /// @dev Only callable by the contract owner (deployer / admin multisig).
    function setBridge(address _bridge) external onlyOwner {
        if (_bridge == address(0)) revert ZeroAddress();
        emit BridgeUpdated(bridge, _bridge);
        bridge = _bridge;
    }

    /// @notice Mints a new NFT with a specific tokenId and tokenURI.
    /// @dev Only callable by the bridge contract, as a result of a verified CCIP message
    ///      (or the initial local mint performed at deploy time on the source chain).
    ///      Reverts if the tokenId already exists, guaranteeing idempotency in case a
    ///      cross-chain message were ever replayed.
    function mint(address to, uint256 tokenId, string memory tokenURI_) external onlyBridge {
        if (_ownerOf(tokenId) != address(0)) revert TokenAlreadyExists(tokenId);
        _safeMint(to, tokenId);
        _setTokenURI(tokenId, tokenURI_);
    }

    /// @notice Convenience view used by the bridge to check idempotency before minting.
    function exists(uint256 tokenId) external view returns (bool) {
        return _ownerOf(tokenId) != address(0);
    }

    /// @notice Burns an NFT. Only callable by the token owner or an approved operator.
    ///         Used by the bridge (via the owner calling sendNFT, which triggers this
    ///         indirectly is NOT how it works -- the bridge itself is only ever approved
    ///         to burn on the owner's behalf when the owner calls sendNFT()).
    function burn(uint256 tokenId) external {
        address tokenOwner = ownerOf(tokenId);
        if (!_isAuthorized(tokenOwner, _msgSender(), tokenId)) {
            revert NotOwnerOrApproved(_msgSender(), tokenId);
        }
        _burn(tokenId);
    }

    // ---------------------------------------------------------------------
    // Required overrides
    // ---------------------------------------------------------------------

    function tokenURI(uint256 tokenId) public view override(ERC721URIStorage) returns (string memory) {
        return super.tokenURI(tokenId);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721URIStorage) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
