// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import "../src/CrossChainNFT.sol";
import "../src/CCIPNFTBridge.sol";
import "./mocks/MockRouterClient.sol";
import "./mocks/MockLinkToken.sol";

contract CCIPNFTBridgeTest is Test {
    uint64 constant DEST_SELECTOR = 3478487238524512106; // Arbitrum Sepolia selector (example)
    uint64 constant SRC_SELECTOR = 14767482510784806043; // Avalanche Fuji selector (example)

    CrossChainNFT nftSource;
    CrossChainNFT nftDest;
    CCIPNFTBridge bridgeSource;
    CCIPNFTBridge bridgeDest;
    MockRouterClient router;
    MockLinkToken link;

    address owner = makeAddr("owner");
    address user = makeAddr("user");
    address receiver = makeAddr("receiver");
    address randomBridge = makeAddr("randomBridge");

    function setUp() public {
        vm.startPrank(owner);

        router = new MockRouterClient();
        link = new MockLinkToken();

        nftSource = new CrossChainNFT("CrossChainNFT", "CCNFT", owner);
        nftDest = new CrossChainNFT("CrossChainNFT", "CCNFT", owner);

        bridgeSource = new CCIPNFTBridge(address(router), address(link), address(nftSource), owner);
        bridgeDest = new CCIPNFTBridge(address(router), address(link), address(nftDest), owner);

        nftSource.setBridge(address(bridgeSource));
        nftDest.setBridge(address(bridgeDest));

        bridgeSource.allowlistDestinationChain(DEST_SELECTOR, true);
        bridgeSource.setRemoteBridge(DEST_SELECTOR, address(bridgeDest));

        bridgeDest.allowlistSourceChain(SRC_SELECTOR, true);
        bridgeDest.setRemoteBridge(SRC_SELECTOR, address(bridgeSource));

        // Fund the source bridge with LINK to pay CCIP fees.
        link.mint(address(bridgeSource), 10 ether);
        vm.stopPrank();

        vm.prank(address(bridgeSource));
        nftSource.mint(user, 1, "ipfs://token-1");
    }

    function test_SendNFT_RevertsIfNotOwner() public {
        vm.prank(randomBridge);
        vm.expectRevert(
            abi.encodeWithSelector(CCIPNFTBridge.NotTokenOwner.selector, randomBridge, 1)
        );
        bridgeSource.sendNFT(DEST_SELECTOR, receiver, 1);
    }

    function test_SendNFT_RevertsIfDestinationNotAllowlisted() public {
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(CCIPNFTBridge.DestinationChainNotAllowed.selector, uint64(999))
        );
        bridgeSource.sendNFT(999, receiver, 1);
    }

    function test_SendNFT_BurnsAndEmitsEvent() public {
        vm.prank(user);
        bytes32 messageId = bridgeSource.sendNFT(DEST_SELECTOR, receiver, 1);

        assertTrue(messageId != bytes32(0));
        assertFalse(nftSource.exists(1));
    }

    function test_SendNFT_RevertsIfInsufficientLink() public {
        // Drain the LINK balance.
        vm.prank(address(bridgeSource));
        link.transfer(owner, link.balanceOf(address(bridgeSource)));

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(CCIPNFTBridge.InsufficientLinkBalance.selector, 0, 0.01 ether)
        );
        bridgeSource.sendNFT(DEST_SELECTOR, receiver, 1);
    }

    function test_CcipReceive_MintsOnDestination() public {
        CCIPNFTBridge.NFTPayload memory payload =
            CCIPNFTBridge.NFTPayload({tokenId: 1, tokenURI: "ipfs://token-1", receiver: receiver});

        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: keccak256("msg-1"),
            sourceChainSelector: SRC_SELECTOR,
            sender: abi.encode(address(bridgeSource)),
            data: abi.encode(payload),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        // Only the router may call ccipReceive.
        vm.prank(address(router));
        bridgeDest.ccipReceive(message);

        assertEq(nftDest.ownerOf(1), receiver);
        assertEq(nftDest.tokenURI(1), "ipfs://token-1");
    }

    function test_CcipReceive_RevertsIfSenderNotAllowlisted() public {
        CCIPNFTBridge.NFTPayload memory payload =
            CCIPNFTBridge.NFTPayload({tokenId: 1, tokenURI: "ipfs://token-1", receiver: receiver});

        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: keccak256("msg-2"),
            sourceChainSelector: SRC_SELECTOR,
            sender: abi.encode(randomBridge),
            data: abi.encode(payload),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        vm.prank(address(router));
        vm.expectRevert(
            abi.encodeWithSelector(CCIPNFTBridge.SenderNotAllowlisted.selector, randomBridge)
        );
        bridgeDest.ccipReceive(message);
    }

    function test_CcipReceive_RevertsIfSourceChainNotAllowlisted() public {
        CCIPNFTBridge.NFTPayload memory payload =
            CCIPNFTBridge.NFTPayload({tokenId: 1, tokenURI: "ipfs://token-1", receiver: receiver});

        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: keccak256("msg-3"),
            sourceChainSelector: 12345,
            sender: abi.encode(address(bridgeSource)),
            data: abi.encode(payload),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        vm.prank(address(router));
        vm.expectRevert(
            abi.encodeWithSelector(CCIPNFTBridge.SourceChainNotAllowed.selector, uint64(12345))
        );
        bridgeDest.ccipReceive(message);
    }

    function test_CcipReceive_IsIdempotent() public {
        CCIPNFTBridge.NFTPayload memory payload =
            CCIPNFTBridge.NFTPayload({tokenId: 1, tokenURI: "ipfs://token-1", receiver: receiver});

        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: keccak256("msg-4"),
            sourceChainSelector: SRC_SELECTOR,
            sender: abi.encode(address(bridgeSource)),
            data: abi.encode(payload),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        vm.prank(address(router));
        bridgeDest.ccipReceive(message);

        vm.prank(address(router));
        vm.expectRevert(
            abi.encodeWithSelector(CCIPNFTBridge.MessageAlreadyProcessed.selector, keccak256("msg-4"))
        );
        bridgeDest.ccipReceive(message);
    }

    function test_EstimateTransferCost() public {
        uint256 cost = bridgeSource.estimateTransferCost(DEST_SELECTOR);
        assertEq(cost, router.fee());
    }

    function test_FullRoundTrip_MetadataPreserved() public {
        string memory originalURI = nftSource.tokenURI(1);

        vm.prank(user);
        bridgeSource.sendNFT(DEST_SELECTOR, receiver, 1);

        // Simulate CCIP delivering the message to the destination bridge.
        CCIPNFTBridge.NFTPayload memory payload =
            CCIPNFTBridge.NFTPayload({tokenId: 1, tokenURI: originalURI, receiver: receiver});

        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: keccak256("msg-roundtrip"),
            sourceChainSelector: SRC_SELECTOR,
            sender: abi.encode(address(bridgeSource)),
            data: abi.encode(payload),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        vm.prank(address(router));
        bridgeDest.ccipReceive(message);

        assertEq(nftDest.ownerOf(1), receiver);
        assertEq(nftDest.tokenURI(1), originalURI);
        assertFalse(nftSource.exists(1));
    }
}
