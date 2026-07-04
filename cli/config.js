require("dotenv").config();
const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..");

function loadDeployment() {
  const deploymentPath = path.join(ROOT, "deployment.json");
  if (!fs.existsSync(deploymentPath)) {
    throw new Error(
      `deployment.json not found at ${deploymentPath}. Run the Foundry deploy script first.`
    );
  }
  return JSON.parse(fs.readFileSync(deploymentPath, "utf-8"));
}

const deployment = loadDeployment();

// Canonical Chainlink CCIP chain selectors (see https://docs.chain.link/ccip/directory).
const CHAINS = {
  "avalanche-fuji": {
    key: "avalancheFuji",
    name: "Avalanche Fuji",
    chainId: 43113,
    rpcEnv: "FUJI_RPC_URL",
    selector: process.env.CCIP_CHAIN_SELECTOR_FUJI || "14767482510784806043",
    nftContractAddress: deployment.avalancheFuji?.nftContractAddress,
    bridgeContractAddress: deployment.avalancheFuji?.bridgeContractAddress,
    linkTokenAddress: process.env.LINK_TOKEN_FUJI,
    explorer: "https://testnet.snowtrace.io/tx/",
  },
  "arbitrum-sepolia": {
    key: "arbitrumSepolia",
    name: "Arbitrum Sepolia",
    chainId: 421614,
    rpcEnv: "ARBITRUM_SEPOLIA_RPC_URL",
    selector: process.env.CCIP_CHAIN_SELECTOR_ARBITRUM_SEPOLIA || "3478487238524512106",
    nftContractAddress: deployment.arbitrumSepolia?.nftContractAddress,
    bridgeContractAddress: deployment.arbitrumSepolia?.bridgeContractAddress,
    linkTokenAddress: process.env.LINK_TOKEN_ARBITRUM_SEPOLIA,
    explorer: "https://sepolia.arbiscan.io/tx/",
  },
};

function getChain(name) {
  const chain = CHAINS[name];
  if (!chain) {
    throw new Error(
      `Unknown chain "${name}". Supported chains: ${Object.keys(CHAINS).join(", ")}`
    );
  }
  const rpcUrl = process.env[chain.rpcEnv];
  if (!rpcUrl) {
    throw new Error(`Missing environment variable ${chain.rpcEnv} for chain "${name}".`);
  }
  return { ...chain, rpcUrl };
}

module.exports = { CHAINS, getChain, deployment, ROOT };
