#!/usr/bin/env node
"use strict";

const { ethers } = require("ethers");
const { randomUUID } = require("crypto");
const fs = require("fs");
const path = require("path");

const { getChain } = require("./config");
const { parseArgs } = require("./lib/argv");
const logger = require("./lib/logger");
const { addTransfer, updateTransfer } = require("./lib/transferStore");

const bridgeAbi = require("./abi/CCIPNFTBridge.json");
const nftAbi = require("./abi/CrossChainNFT.json");

function loadTokenMetadata(tokenURI) {
  // Best-effort parse of on-chain tokenURI into { name, description, image }.
  // Supports plain http(s) JSON URIs and inline `data:application/json;base64,...` URIs.
  // Falls back to a minimal object if metadata can't be fetched/parsed (e.g. ipfs:// without
  // a gateway, or offline environments) -- the transfer itself is never blocked on this.
  const fallback = { name: `Token`, description: "", image: "" };
  try {
    if (tokenURI.startsWith("data:application/json;base64,")) {
      const json = Buffer.from(tokenURI.split(",")[1], "base64").toString("utf-8");
      const parsed = JSON.parse(json);
      return { name: parsed.name || "", description: parsed.description || "", image: parsed.image || "" };
    }
  } catch (err) {
    logger.warn(`Could not parse inline tokenURI metadata: ${err.message}`);
  }
  return fallback;
}

async function main() {
  const args = parseArgs(process.argv, ["tokenId", "from", "to", "receiver"]);

  const { tokenId, from, to, receiver } = args;

  if (!tokenId || !from || !to || !receiver) {
    logger.error(
      "Missing required arguments. Usage: npm run transfer -- --tokenId=<id> --from=<chain> --to=<chain> --receiver=<address>"
    );
    process.exitCode = 1;
    return;
  }

  if (!ethers.isAddress(receiver)) {
    logger.error(`Invalid receiver address: ${receiver}`);
    process.exitCode = 1;
    return;
  }

  const transferId = randomUUID();
  logger.info(`=== Starting transfer ${transferId} ===`);
  logger.info(`tokenId=${tokenId} from=${from} to=${to} receiver=${receiver}`);

  let sourceChain, destChain;
  try {
    sourceChain = getChain(from);
    destChain = getChain(to);
  } catch (err) {
    logger.error(`Configuration error: ${err.message}`);
    process.exitCode = 1;
    return;
  }

  if (!sourceChain.bridgeContractAddress || !sourceChain.nftContractAddress) {
    logger.error(
      `Missing contract addresses for ${from} in deployment.json. Deploy contracts first.`
    );
    process.exitCode = 1;
    return;
  }

  const privateKey = process.env.PRIVATE_KEY;
  if (!privateKey) {
    logger.error("PRIVATE_KEY not set in environment (.env).");
    process.exitCode = 1;
    return;
  }

  let record = {
    transferId,
    tokenId: String(tokenId),
    sourceChain: from,
    destinationChain: to,
    sender: null,
    receiver,
    ccipMessageId: null,
    sourceTxHash: null,
    destinationTxHash: null,
    status: "initiated",
    metadata: { name: "", description: "", image: "" },
    timestamp: new Date().toISOString(),
  };

  // Persist the "initiated" record immediately, before anything that could throw, so the
  // audit trail exists (and can be updated to "failed") even if a later step blows up.
  addTransfer(record);
  logger.info(`Transfer record ${transferId} created with status "initiated".`);

  try {
    const provider = new ethers.JsonRpcProvider(sourceChain.rpcUrl);
    const wallet = new ethers.Wallet(privateKey, provider);
    record.sender = wallet.address;
    updateTransfer(transferId, { sender: wallet.address });

    const nftContract = new ethers.Contract(sourceChain.nftContractAddress, nftAbi, provider);
    const bridgeContract = new ethers.Contract(
      sourceChain.bridgeContractAddress,
      bridgeAbi,
      wallet
    );

    logger.info(`Verifying ownership of tokenId ${tokenId} on ${sourceChain.name}...`);
    const currentOwner = await nftContract.ownerOf(tokenId);
    if (currentOwner.toLowerCase() !== wallet.address.toLowerCase()) {
      throw new Error(
        `Wallet ${wallet.address} does not own tokenId ${tokenId} (owner is ${currentOwner}).`
      );
    }

    const tokenURI = await nftContract.tokenURI(tokenId);
    record.metadata = loadTokenMetadata(tokenURI);
    record.metadata.name = record.metadata.name || `Token #${tokenId}`;

    logger.info(`Estimating CCIP transfer cost to ${destChain.name}...`);
    const estimatedFee = await bridgeContract.estimateTransferCost(destChain.selector);
    logger.info(`Estimated LINK fee: ${ethers.formatEther(estimatedFee)} LINK`);

    record.status = "in-progress";
    updateTransfer(transferId, { status: "in-progress" });

    logger.info(
      `Submitting sendNFT(destinationChainSelector=${destChain.selector}, receiver=${receiver}, tokenId=${tokenId}) on ${sourceChain.name}...`
    );

    const tx = await bridgeContract.sendNFT(destChain.selector, receiver, tokenId);
    logger.info(`Transaction submitted. Hash: ${tx.hash}`);

    record.sourceTxHash = tx.hash;
    updateTransfer(transferId, { sourceTxHash: tx.hash });

    const receipt = await tx.wait();
    if (receipt.status !== 1) {
      throw new Error(`Source transaction reverted (status=${receipt.status}).`);
    }
    logger.info(`Source transaction confirmed in block ${receipt.blockNumber}.`);

    // Extract the CCIP messageId from the NFTSent event.
    let ccipMessageId = null;
    for (const log of receipt.logs) {
      try {
        const parsed = bridgeContract.interface.parseLog(log);
        if (parsed && parsed.name === "NFTSent") {
          ccipMessageId = parsed.args.messageId;
          break;
        }
      } catch (_) {
        // Not a log this interface can parse; skip.
      }
    }

    if (ccipMessageId) {
      logger.info(`CCIP messageId: ${ccipMessageId}`);
      logger.info(
        `Track delivery at: https://ccip.chain.link/msg/${ccipMessageId}`
      );
    } else {
      logger.warn("Could not find NFTSent event in transaction receipt logs.");
    }

    record.ccipMessageId = ccipMessageId;
    record.status = "completed";
    updateTransfer(transferId, {
      ccipMessageId,
      status: "completed",
    });

    logger.info(`=== Transfer ${transferId} initiated successfully ===`);
    logger.info(
      `Source tx: ${sourceChain.explorer}${tx.hash}`
    );
    logger.info(
      "Note: 'completed' here means the source-chain send transaction succeeded. " +
        "Cross-chain delivery/minting on the destination chain happens asynchronously via " +
        "the Chainlink CCIP network -- check the CCIP Explorer link above for final status."
    );
  } catch (err) {
    logger.error(`Transfer ${transferId} failed: ${err.message}`);
    try {
      updateTransfer(transferId, { status: "failed" });
    } catch (updateErr) {
      logger.error(`Could not update transfer record: ${updateErr.message}`);
    }
    process.exitCode = 1;
  }
}

main();
