// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import "./CrossChainNFT.sol";

/// @title CCIPNFTBridge
/// @notice Sends and receives NFT "burn-and-mint" cross-chain transfers using Chainlink CCIP.
///         The NFT is burned on the source chain and an identical tokenId/tokenURI is minted
///         on the destination chain once the CCIP message is verified and delivered.
contract CCIPNFTBridge is CCIPReceiver, IERC721Receiver, Ownable {
    CrossChainNFT public immutable nft;
    IRouterClient public router;
    IERC20 public linkToken;

    /// @dev Address of the sibling CCIPNFTBridge deployment on each remote chain, keyed by
    ///      CCIP chain selector. Used both to address outbound messages and to authenticate
    ///      inbound ones.
    mapping(uint64 => address) public remoteBridges;
    mapping(uint64 => bool) public allowlistedDestinationChains;
    mapping(uint64 => bool) public allowlistedSourceChains;

    /// @dev Guards against ever processing the same CCIP message twice. CCIP itself
    ///      guarantees exactly-once delivery per message id, but this is kept as a
    ///      defense-in-depth idempotency check.
    mapping(bytes32 => bool) public processedMessages;

    struct NFTPayload {
        uint256 tokenId;
        string tokenURI;
        address receiver;
    }

    uint256 public gasLimitForDestination = 400_000;

    event NFTSent(
        bytes32 indexed messageId,
        uint64 indexed destinationChainSelector,
        address receiver,
        uint256 tokenId,
        string tokenURI
    );

    event NFTReceived(
        bytes32 indexed messageId,
        uint64 indexed sourceChainSelector,
        address receiver,
        uint256 tokenId,
        string tokenURI
    );

    event RemoteBridgeUpdated(uint64 indexed chainSelector, address bridgeAddress);
    event DestinationChainAllowlisted(uint64 indexed chainSelector, bool allowed);
    event SourceChainAllowlisted(uint64 indexed chainSelector, bool allowed);
    event GasLimitUpdated(uint256 oldLimit, uint256 newLimit);

    error InvalidReceiver();
    error NotTokenOwner(address caller, uint256 tokenId);
    error DestinationChainNotAllowed(uint64 chainSelector);
    error SourceChainNotAllowed(uint64 chainSelector);
    error SenderNotAllowlisted(address sender);
    error RemoteBridgeNotSet(uint64 chainSelector);
    error InsufficientLinkBalance(uint256 balance, uint256 required);
    error MessageAlreadyProcessed(bytes32 messageId);

    constructor(address _router, address _link, address _nft, address initialOwner)
        CCIPReceiver(_router)
        Ownable(initialOwner)
    {
        router = IRouterClient(_router);
        linkToken = IERC20(_link);
        nft = CrossChainNFT(_nft);
    }

    // ---------------------------------------------------------------------
    // Admin configuration
    // ---------------------------------------------------------------------

    /// @notice Allowlists (or de-lists) a destination chain that this bridge may send to.
    function allowlistDestinationChain(uint64 chainSelector, bool allowed) external onlyOwner {
        allowlistedDestinationChains[chainSelector] = allowed;
        emit DestinationChainAllowlisted(chainSelector, allowed);
    }

    /// @notice Allowlists (or de-lists) a source chain that this bridge may receive from.
    function allowlistSourceChain(uint64 chainSelector, bool allowed) external onlyOwner {
        allowlistedSourceChains[chainSelector] = allowed;
        emit SourceChainAllowlisted(chainSelector, allowed);
    }

    /// @notice Registers the sibling bridge contract address deployed on `chainSelector`.
    ///         This address is used both as the CCIP message receiver when sending, and as
    ///         the expected sender when validating inbound messages.
    function setRemoteBridge(uint64 chainSelector, address bridgeAddress) external onlyOwner {
        remoteBridges[chainSelector] = bridgeAddress;
        emit RemoteBridgeUpdated(chainSelector, bridgeAddress);
    }

    function setGasLimitForDestination(uint256 newLimit) external onlyOwner {
        emit GasLimitUpdated(gasLimitForDestination, newLimit);
        gasLimitForDestination = newLimit;
    }

    function withdrawLink(address to, uint256 amount) external onlyOwner {
        linkToken.transfer(to, amount);
    }

    // ---------------------------------------------------------------------
    // Send
    // ---------------------------------------------------------------------

    /// @notice Burns `tokenId` on this (source) chain and sends a CCIP message instructing
    ///         the sibling bridge on `destinationChainSelector` to mint an identical token
    ///         (same tokenId + tokenURI) to `receiver`.
    /// @dev Fees are paid in LINK, which must be pre-funded to this contract.
    function sendNFT(uint64 destinationChainSelector, address receiver, uint256 tokenId)
        external
        returns (bytes32 messageId)
    {
        if (receiver == address(0)) revert InvalidReceiver();
        if (!allowlistedDestinationChains[destinationChainSelector]) {
            revert DestinationChainNotAllowed(destinationChainSelector);
        }

        address remoteBridge = remoteBridges[destinationChainSelector];
        if (remoteBridge == address(0)) revert RemoteBridgeNotSet(destinationChainSelector);

        if (nft.ownerOf(tokenId) != msg.sender) revert NotTokenOwner(msg.sender, tokenId);

        // Preserve metadata before burning.
        string memory uri = nft.tokenURI(tokenId);

        // Burn-and-mint: destroy the token on the source chain so total supply across all
        // chains stays constant.
        nft.burn(tokenId);

        Client.EVM2AnyMessage memory evm2AnyMessage = _buildCCIPMessage(remoteBridge, tokenId, uri, receiver);

        uint256 fee = router.getFee(destinationChainSelector, evm2AnyMessage);

        uint256 balance = linkToken.balanceOf(address(this));
        if (balance < fee) revert InsufficientLinkBalance(balance, fee);

        linkToken.approve(address(router), fee);

        messageId = router.ccipSend(destinationChainSelector, evm2AnyMessage);

        emit NFTSent(messageId, destinationChainSelector, receiver, tokenId, uri);
    }

    // ---------------------------------------------------------------------
    // Receive
    // ---------------------------------------------------------------------

    /// @notice Entry point invoked by the CCIP Router when a message addressed to this
    ///         contract is delivered. Validates the source chain and sender before minting.
    function _ccipReceive(Client.Any2EVMMessage memory message) internal override {
        bytes32 messageId = message.messageId;

        if (processedMessages[messageId]) revert MessageAlreadyProcessed(messageId);
        processedMessages[messageId] = true;

        uint64 sourceChainSelector = message.sourceChainSelector;
        if (!allowlistedSourceChains[sourceChainSelector]) {
            revert SourceChainNotAllowed(sourceChainSelector);
        }

        address sender = abi.decode(message.sender, (address));
        address expectedSender = remoteBridges[sourceChainSelector];
        if (expectedSender == address(0) || sender != expectedSender) {
            revert SenderNotAllowlisted(sender);
        }

        NFTPayload memory payload = abi.decode(message.data, (NFTPayload));

        // Idempotency: never mint a duplicate tokenId even if a message were somehow
        // reprocessed. CCIP already guarantees exactly-once delivery per messageId, this
        // is a defense-in-depth check at the application layer.
        if (!nft.exists(payload.tokenId)) {
            nft.mint(payload.receiver, payload.tokenId, payload.tokenURI);
        }

        emit NFTReceived(messageId, sourceChainSelector, payload.receiver, payload.tokenId, payload.tokenURI);
    }

    // ---------------------------------------------------------------------
    // Fee estimation
    // ---------------------------------------------------------------------

    /// @notice Estimates the LINK fee required to transfer an NFT to `destinationChainSelector`.
    function estimateTransferCost(uint64 destinationChainSelector) external view returns (uint256) {
        address remoteBridge = remoteBridges[destinationChainSelector];
        // Use a representative dummy payload of the same shape/size as a real transfer so the
        // fee estimate is accurate (CCIP fees scale with payload size and gas limit).
        Client.EVM2AnyMessage memory evm2AnyMessage =
            _buildCCIPMessage(remoteBridge, 0, "ipfs://bafybeigdyrztqexampleexamplecidforsizeestimateonly", address(0));

        return router.getFee(destinationChainSelector, evm2AnyMessage);
    }

    function _buildCCIPMessage(address remoteBridge, uint256 tokenId, string memory uri, address receiver)
        internal
        view
        returns (Client.EVM2AnyMessage memory)
    {
        NFTPayload memory payload = NFTPayload({tokenId: tokenId, tokenURI: uri, receiver: receiver});

        return Client.EVM2AnyMessage({
            receiver: abi.encode(remoteBridge),
            data: abi.encode(payload),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({gasLimit: gasLimitForDestination})),
            feeToken: address(linkToken)
        });
    }

    /// @notice Required for safe NFT transfers to this contract (not used by the burn-and-mint
    ///         flow, but kept for compatibility/future lock-and-mint style extensions).
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
