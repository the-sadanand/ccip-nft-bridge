// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Minimal mock of the CCIP Router used purely for unit testing message
///         construction/encoding and fee handling in isolation, without depending on the
///         full CCIP protocol stack.
contract MockRouterClient is IRouterClient {
    uint256 public fee = 0.01 ether;
    bytes32 public lastMessageId;
    uint64 public lastDestinationChainSelector;
    Client.EVM2AnyMessage public lastMessage;

    event MockCCIPSend(uint64 destinationChainSelector, Client.EVM2AnyMessage message);

    function setFee(uint256 _fee) external {
        fee = _fee;
    }

    function isChainSupported(uint64) external pure returns (bool) {
        return true;
    }

    function getSupportedTokens(uint64) external pure returns (address[] memory) {
        address[] memory tokens = new address[](0);
        return tokens;
    }

    function getFee(uint64, Client.EVM2AnyMessage memory) external view returns (uint256) {
        return fee;
    }

    function ccipSend(uint64 destinationChainSelector, Client.EVM2AnyMessage calldata message)
        external
        payable
        returns (bytes32)
    {
        IERC20(message.feeToken).transferFrom(msg.sender, address(this), fee);

        lastMessageId = keccak256(abi.encode(destinationChainSelector, message, block.timestamp));
        lastDestinationChainSelector = destinationChainSelector;

        emit MockCCIPSend(destinationChainSelector, message);
        return lastMessageId;
    }
}
