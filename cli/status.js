#!/usr/bin/env node
"use strict";

const { ethers } = require("ethers");
const { getChain } = require("./config");
const { parseArgs } = require("./lib/argv");
const logger = require("./lib/logger");
const { readAll, updateTransfer } = require("./lib/transferStore");
const nftAbi = require("./abi/CrossChainNFT.json");

async function main() {
  const args = parseArgs(process.argv, ["transferId"]);
  const { transferId } = args;

  const records = readAll();
  const targets = transferId ? records.filter((r) => r.transferId === transferId) : records;

  if (targets.length === 0) {
    logger.info("No matching transfer records found.");
    return;
  }

  for (const record of targets) {
    try {
      const destChain = getChain(record.destinationChain);
      if (!destChain.nftContractAddress) {
        logger.warn(`No destination NFT address configured for ${record.destinationChain}`);
        continue;
      }
      const provider = new ethers.JsonRpcProvider(destChain.rpcUrl);
      const nft = new ethers.Contract(destChain.nftContractAddress, nftAbi, provider);

      const exists = await nft.exists(record.tokenId);
      if (exists) {
        const owner = await nft.ownerOf(record.tokenId);
        logger.info(
          `[${record.transferId}] tokenId ${record.tokenId} minted on ${destChain.name}, owner=${owner}`
        );
        if (record.status !== "delivered") {
          updateTransfer(record.transferId, { status: "delivered" });
        }
      } else {
        logger.info(
          `[${record.transferId}] tokenId ${record.tokenId} not yet minted on ${destChain.name} (still in flight).`
        );
      }
    } catch (err) {
      logger.error(`Failed to check status for ${record.transferId}: ${err.message}`);
    }
  }
}

main();
