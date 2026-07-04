// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/CrossChainNFT.sol";

contract CrossChainNFTTest is Test {
    CrossChainNFT nft;

    address owner = makeAddr("owner");
    address bridge = makeAddr("bridge");
    address user = makeAddr("user");
    address stranger = makeAddr("stranger");

    function setUp() public {
        vm.prank(owner);
        nft = new CrossChainNFT("CrossChainNFT", "CCNFT", owner);

        vm.prank(owner);
        nft.setBridge(bridge);
    }

    function test_SetBridge_OnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        nft.setBridge(stranger);

        vm.prank(owner);
        nft.setBridge(bridge);
        assertEq(nft.bridge(), bridge);
    }

    function test_Mint_OnlyBridge() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(CrossChainNFT.NotBridge.selector, stranger));
        nft.mint(user, 1, "ipfs://token-1");

        vm.prank(bridge);
        nft.mint(user, 1, "ipfs://token-1");

        assertEq(nft.ownerOf(1), user);
        assertEq(nft.tokenURI(1), "ipfs://token-1");
    }

    function test_Mint_RevertsIfTokenAlreadyExists() public {
        vm.prank(bridge);
        nft.mint(user, 1, "ipfs://token-1");

        vm.prank(bridge);
        vm.expectRevert(abi.encodeWithSelector(CrossChainNFT.TokenAlreadyExists.selector, 1));
        nft.mint(user, 1, "ipfs://token-1-dup");
    }

    function test_Burn_OnlyOwnerOrApproved() public {
        vm.prank(bridge);
        nft.mint(user, 1, "ipfs://token-1");

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(CrossChainNFT.NotOwnerOrApproved.selector, stranger, 1)
        );
        nft.burn(1);

        vm.prank(user);
        nft.burn(1);

        assertFalse(nft.exists(1));
    }

    function test_Burn_ApprovedOperatorCanBurn() public {
        vm.prank(bridge);
        nft.mint(user, 1, "ipfs://token-1");

        vm.prank(user);
        nft.approve(stranger, 1);

        vm.prank(stranger);
        nft.burn(1);

        assertFalse(nft.exists(1));
    }

    function test_Exists() public {
        assertFalse(nft.exists(1));
        vm.prank(bridge);
        nft.mint(user, 1, "ipfs://token-1");
        assertTrue(nft.exists(1));
    }
}
