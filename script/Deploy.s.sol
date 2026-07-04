// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "../src/CrossChainNFT.sol";
import "../src/CCIPNFTBridge.sol";

/// @notice Deploys CrossChainNFT + CCIPNFTBridge to both Avalanche Fuji and Arbitrum
///         Sepolia in a single run using Foundry's multi-fork scripting, wires up the
///         bridges to trust each other, pre-mints test tokenId `1` on Fuji to the
///         deployer, and writes every address to `deployment.json`.
///
/// Usage:
///   forge script script/Deploy.s.sol:Deploy --broadcast -vvvv
///
/// Required env vars (see .env.example):
///   PRIVATE_KEY, FUJI_RPC_URL, ARBITRUM_SEPOLIA_RPC_URL,
///   CCIP_ROUTER_FUJI, CCIP_ROUTER_ARBITRUM_SEPOLIA,
///   LINK_TOKEN_FUJI, LINK_TOKEN_ARBITRUM_SEPOLIA,
///   CCIP_CHAIN_SELECTOR_FUJI, CCIP_CHAIN_SELECTOR_ARBITRUM_SEPOLIA
contract Deploy is Script {
    // Official Chainlink CCIP chain selectors (constant across deployments, but also
    // overridable via env in case Chainlink updates them).
    uint64 constant DEFAULT_FUJI_SELECTOR = 14767482510784806043;
    uint64 constant DEFAULT_ARBITRUM_SEPOLIA_SELECTOR = 3478487238524512106;

    string constant TEST_TOKEN_URI = "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi/1.json";
    uint256 constant TEST_TOKEN_ID = 1;

    struct ChainDeployment {
        address nft;
        address bridge;
    }

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        uint64 fujiSelector = _envOrDefault("CCIP_CHAIN_SELECTOR_FUJI", DEFAULT_FUJI_SELECTOR);
        uint64 arbSelector = _envOrDefault("CCIP_CHAIN_SELECTOR_ARBITRUM_SEPOLIA", DEFAULT_ARBITRUM_SEPOLIA_SELECTOR);

        uint256 fujiFork = vm.createFork(vm.envString("FUJI_RPC_URL"));
        uint256 arbFork = vm.createFork(vm.envString("ARBITRUM_SEPOLIA_RPC_URL"));

        // --- Deploy on Avalanche Fuji ---
        vm.selectFork(fujiFork);
        vm.startBroadcast(deployerKey);
        ChainDeployment memory fuji = _deployChain(
            vm.envAddress("CCIP_ROUTER_FUJI"), vm.envAddress("LINK_TOKEN_FUJI"), deployer
        );
        // Pre-mint the test NFT directly (deployer is temporarily the bridge for this one call
        // path is avoided; instead we mint through the real bridge-only path by having the
        // NFT's bridge already set, then minting via the bridge's owner-only bootstrap is not
        // exposed, so we mint BEFORE locking down by calling nft.mint via bridge context).
        CrossChainNFT(fuji.nft).setBridge(deployer);
        CrossChainNFT(fuji.nft).mint(deployer, TEST_TOKEN_ID, TEST_TOKEN_URI);
        CrossChainNFT(fuji.nft).setBridge(fuji.bridge);
        vm.stopBroadcast();

        // --- Deploy on Arbitrum Sepolia ---
        vm.selectFork(arbFork);
        vm.startBroadcast(deployerKey);
        ChainDeployment memory arb = _deployChain(
            vm.envAddress("CCIP_ROUTER_ARBITRUM_SEPOLIA"), vm.envAddress("LINK_TOKEN_ARBITRUM_SEPOLIA"), deployer
        );
        vm.stopBroadcast();

        // --- Wire Fuji bridge -> trusts Arbitrum Sepolia bridge ---
        vm.selectFork(fujiFork);
        vm.startBroadcast(deployerKey);
        CCIPNFTBridge(fuji.bridge).allowlistDestinationChain(arbSelector, true);
        CCIPNFTBridge(fuji.bridge).allowlistSourceChain(arbSelector, true);
        CCIPNFTBridge(fuji.bridge).setRemoteBridge(arbSelector, arb.bridge);
        vm.stopBroadcast();

        // --- Wire Arbitrum Sepolia bridge -> trusts Fuji bridge ---
        vm.selectFork(arbFork);
        vm.startBroadcast(deployerKey);
        CCIPNFTBridge(arb.bridge).allowlistDestinationChain(fujiSelector, true);
        CCIPNFTBridge(arb.bridge).allowlistSourceChain(fujiSelector, true);
        CCIPNFTBridge(arb.bridge).setRemoteBridge(fujiSelector, fuji.bridge);
        vm.stopBroadcast();

        _writeDeploymentJson(fuji, arb);

        console2.log("=== Deployment complete ===");
        console2.log("Fuji NFT:            ", fuji.nft);
        console2.log("Fuji Bridge:         ", fuji.bridge);
        console2.log("Arbitrum Sepolia NFT:", arb.nft);
        console2.log("Arbitrum Sepolia Br: ", arb.bridge);
        console2.log("Deployer / test token owner:", deployer);
        console2.log("Test tokenId minted on Fuji:", TEST_TOKEN_ID);
    }

    function _deployChain(address router, address link, address initialOwner)
        internal
        returns (ChainDeployment memory)
    {
        CrossChainNFT nft = new CrossChainNFT("CrossChainNFT", "CCNFT", initialOwner);
        CCIPNFTBridge bridge = new CCIPNFTBridge(router, link, address(nft), initialOwner);
        nft.setBridge(address(bridge));
        return ChainDeployment({nft: address(nft), bridge: address(bridge)});
    }

    function _writeDeploymentJson(ChainDeployment memory fuji, ChainDeployment memory arb) internal {
        // Built by hand (rather than via vm.serializeAddress) to guarantee the exact key
        // names/ordering required by the deployment.json schema.
        string memory json = string.concat(
            "{\n",
            '  "avalancheFuji": {\n',
            '    "nftContractAddress": "',
            vm.toString(fuji.nft),
            '",\n',
            '    "bridgeContractAddress": "',
            vm.toString(fuji.bridge),
            '"\n',
            "  },\n",
            '  "arbitrumSepolia": {\n',
            '    "nftContractAddress": "',
            vm.toString(arb.nft),
            '",\n',
            '    "bridgeContractAddress": "',
            vm.toString(arb.bridge),
            '"\n',
            "  }\n",
            "}\n"
        );

        vm.writeFile("deployment.json", json);
    }

    function _envOrDefault(string memory key, uint64 defaultValue) internal view returns (uint64) {
        try vm.envUint(key) returns (uint256 value) {
            return uint64(value);
        } catch {
            return defaultValue;
        }
    }
}
